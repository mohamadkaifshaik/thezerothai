// poll_vote: W6 emulator load smoke (W6-21, docs/plans/ui-w6-composer-extras.md "W6-21"; ADR-0029 "Cost impact"). One file, one
// timeline of phases, all against ONE local API process (one "instance") and the Firebase emulators. Never point it at dzeroth-dev or
// dzeroth-prod: it creates about 3,500 users and raises every vote, post and read-budget cap.
//
//   setup()       Mints NUM_VOTERS + 8 users (voters have never made a call; the author is user 0), seeds the poll that the cold
//                 phase uses, a poll with a 1 minute duration (POLL_MIN_DURATION=1m on the API) that closes while the script idles,
//                 and MIX_POLLS polls for the typical mix. Then it idles COLD_SETTLE s (default 70, longer than CACHE_TTL 60 s and
//                 the 1 minute poll) so no per-instance cache holds anything and the short poll is closed.
//   cold_calls    t=0, ONE virtual user, serial; every call is preceded by a `W6 STEP <name> <iso time>` marker so the analyzer can
//                 give each request line its case: CreatePost with a poll and a plain post; VotePoll by a cold viewer, the replay
//                 (same key), ALREADY_VOTED (new key, other choice), a second cold viewer (the post is now cached), a REPOST id
//                 (the +2 reads path), refusals (the author, a choice out of range, a post without a poll), a vote on the closed
//                 poll (POLL_CLOSED); GetPost of the closed poll (counts visible), of an open poll by a voter and a non-voter.
//   hot_poll      t=HOT_START (default 5): HOT_RATE (default 50) VotePoll a second for HOT_DURATION s (default 60) on ONE poll,
//                 each from a different voter (a natural key allows one vote per account per poll), so 3,000 distinct voters. The
//                 rule-3 counter-contention shape (stage-ladder trigger "more than 1 vote a second on one poll for 5 minutes").
//                 Counters: poll_vote_ok, poll_vote_unavailable (contention), poll_vote_other.
//   mix           t=MIX_START (default 5): the typical mix, MIX_RATE (default 10) calls a second for MIX_DURATION s (default 30) over
//                 MIX_POLLS (default 20) polls from other voters: 3 of 4 calls are a VotePoll, 1 of 4 a GetPost of a poll.
//   verify        t=VERIFY_START (default 100): GetPost of the hot poll by its author, then poll.total must equal the number of
//                 2xx votes and the choice counts must sum to it (nothing lost, nothing double counted).
//
// Reads are NOT a k6 metric: they come from the API request log (`fs_reads`, `fs_writes`, `fs_deletes`, `txn_attempts`, `outcome`,
// `contention`, `code`), see loadtest/analyze_poll.js. k6 prints `W6 PHASE <name> <iso>` and `W6 STEP <name> <iso>` lines (stdout/stderr)
// that the analyzer uses to cut the log. Latency is emulator latency, indicative only. The emulator's locking does NOT reproduce real
// Firestore's roughly 1 write/s per document soft limit: the hot-poll result is behaviour (nothing lost, retries bounded), not a
// contention forecast.
//
// API requirements (a local API against the emulators; load-testing skill): ENV=local FEATURE_POSTS=on FEATURE_ENGAGEMENT=on
// FEATURE_POLLS=on, POLL_MIN_DURATION=1m, and these raised (they are per instance and per user, and every virtual user shares
// 127.0.0.1): RATE_LIMIT_PER_IP_PER_MIN, RATE_LIMIT_PRE_AUTH_IP_PER_MIN, RATE_LIMIT_PER_USER_PER_MIN, RATE_LIMIT_POLL_VOTE_PER_MIN,
// POLL_VOTES_PER_DAY, POLL_VOTES_PER_DAY_NEW_ACCOUNT, READ_BUDGET_PER_UID_PER_DAY, RATE_LIMIT_POST_CREATE_PER_MIN,
// QUOTA_POSTS_PER_DAY, QUOTA_NEW_ACCOUNT_POSTS_PER_DAY. The exact values of the recorded run are in docs/reviews/cost-model.md
// section 16.
//
//   k6 run loadtest/poll_vote.js      # or: make loadtest SCENARIO=poll_vote
//   node loadtest/analyze_poll.js api.log k6.out
import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';
import { Counter } from 'k6/metrics';
import { mintUsers, rpcCall } from './graph_common.js';

const POSTS = 'dzeroth.posts.v1.PostService';
const ENG = 'dzeroth.engagement.v1.EngagementService';

const NUM_VOTERS = parseInt(__ENV.NUM_VOTERS || '3300', 10);
const HOT_VOTERS = parseInt(__ENV.HOT_VOTERS || '3100', 10); // voters [0, HOT_VOTERS) vote on the hot poll, the rest are the mix's
const MIX_POLLS = parseInt(__ENV.MIX_POLLS || '20', 10);
const COLD_SETTLE = parseInt(__ENV.COLD_SETTLE || '70', 10);
const HOT_START = parseInt(__ENV.HOT_START || '5', 10);
const HOT_RATE = parseInt(__ENV.HOT_RATE || '50', 10);
const HOT_DURATION = parseInt(__ENV.HOT_DURATION || '60', 10);
const MIX_START = parseInt(__ENV.MIX_START || '5', 10);
const MIX_RATE = parseInt(__ENV.MIX_RATE || '10', 10);
const MIX_DURATION = parseInt(__ENV.MIX_DURATION || '30', 10);
const VERIFY_START = parseInt(__ENV.VERIFY_START || '100', 10);

const voteOk = new Counter('poll_vote_ok');
const voteUnavailable = new Counter('poll_vote_unavailable');
const voteOther = new Counter('poll_vote_other');
const mixOther = new Counter('poll_mix_unexpected');

export const options = {
  setupTimeout: '3600s',
  scenarios: {
    cold_calls: { executor: 'shared-iterations', exec: 'coldCalls', vus: 1, iterations: 1, startTime: '0s', maxDuration: '5m' },
    hot_poll: {
      executor: 'constant-arrival-rate', exec: 'hotPoll', rate: HOT_RATE, timeUnit: '1s', duration: `${HOT_DURATION}s`,
      preAllocatedVUs: 30, maxVUs: 120, startTime: `${HOT_START + 30}s`,
    },
    mix: {
      executor: 'constant-arrival-rate', exec: 'mixCalls', rate: MIX_RATE, timeUnit: '1s', duration: `${MIX_DURATION}s`,
      preAllocatedVUs: 10, maxVUs: 40, startTime: `${MIX_START + 30 + HOT_DURATION + 5}s`,
    },
    verify: { executor: 'shared-iterations', exec: 'verifyHot', vus: 1, iterations: 1, startTime: `${VERIFY_START + 30}s`, maxDuration: '2m' },
  },
  thresholds: { poll_mix_unexpected: ['count==0'] },
};

function must(res, what) {
  if (res.status !== 200) throw new Error(`setup: ${what}: status ${res.status}: ${String(res.body).slice(0, 300)}`);
  return res;
}

const stamp = () => new Date().toISOString();
const phase = (name) => console.log(`W6 PHASE ${name} ${stamp()}`);
const step = (name) => console.log(`W6 STEP ${name} ${stamp()}`);

let seq = 0;
function key(run, what) {
  seq++;
  return `w6-${run}-${what}-${exec.vu.idInTest}-${seq}-0123456789`.slice(0, 64);
}

function createPoll(user, run, what, minutes, choices) {
  const res = rpcCall(
    POSTS, 'CreatePost',
    { idempotencyKey: key(run, what), text: `W6 poll ${what} ${run}`, poll: { choices: choices || ['red', 'green', 'blue', 'grey'], durationMinutes: minutes } },
    user.idToken, 'CreatePost',
  );
  return must(res, `CreatePost poll ${what}`).json('post.post.postId');
}

export function setup() {
  const run = Math.floor(Date.now() / 1000).toString(36);
  const users = mintUsers(NUM_VOTERS + 8, 'pollv');
  const author = users[0];
  const voters = users.slice(1, 1 + NUM_VOTERS).map((u) => u.idToken); // tokens only: setup data is copied into every VU
  const extra = users.slice(1 + NUM_VOTERS); // 7 spare accounts for the cold phase (reposter, viewers)
  const mk = (what, minutes) => createPoll(author, run, what, minutes);
  const hot = mk('hot', 1440);
  const cold = mk('cold', 1440);
  const cold2 = mk('cold2', 1440);
  const short = mk('short', 1); // closes during the idle below
  const mix = [];
  for (let i = 0; i < MIX_POLLS; i++) mix.push(mk(`mix${i}`, 1440));
  const plain = must(rpcCall(POSTS, 'CreatePost', { idempotencyKey: key(run, 'plain'), text: `W6 plain ${run}` }, author.idToken), 'CreatePost plain').json('post.post.postId');
  // A REPOST of `cold` by a spare account; a third account votes through its id (the +2 reads path).
  const rp = must(rpcCall(ENG, 'RepostPost', { idempotencyKey: key(run, 'rp'), postId: cold }, extra[0].idToken), 'RepostPost').json('repostPostId');
  console.log(`W6 SETUP run=${run} voters=${voters.length} hot=${hot} cold=${cold} short=${short} mix=${mix.length}`);
  sleep(COLD_SETTLE);
  return { run, author, voters, extra, hot, cold, cold2, short, mix, plain, repost: rp };
}

export function coldCalls(d) {
  phase('cold_calls');
  const [v1, v2, v3, v4] = [d.extra[1], d.extra[2], d.extra[3], d.extra[4]];
  const call = (name, svc, method, body, tok) => { step(name); return rpcCall(svc, method, body, tok, method); };
  const vote = (name, who, post, choice, k) => call(name, ENG, 'VotePoll', { idempotencyKey: k || key(d.run, name), postId: post, choiceIndex: choice }, who.idToken);
  // Polls
  step('create_poll_cold'); // CreatePost with a poll; the author's caches are cold after the idle
  rpcCall(POSTS, 'CreatePost', { idempotencyKey: key(d.run, 'cp'), text: `W6 cold poll ${d.run}`, poll: { choices: ['a', 'b'], durationMinutes: 60 } }, d.author.idToken, 'CreatePost');
  step('create_poll_warm');
  rpcCall(POSTS, 'CreatePost', { idempotencyKey: key(d.run, 'cp2'), text: `W6 warm poll ${d.run}`, poll: { choices: ['a', 'b', 'c'], durationMinutes: 60 } }, d.author.idToken, 'CreatePost');
  step('create_plain_warm');
  rpcCall(POSTS, 'CreatePost', { idempotencyKey: key(d.run, 'cp3'), text: `W6 plain again ${d.run}` }, d.author.idToken, 'CreatePost');
  // Votes
  const k1 = key(d.run, 'v1');
  vote('vote_new_cold', v1, d.cold, 1, k1);
  vote('vote_replay', v1, d.cold, 1, k1);
  vote('vote_already_voted', v1, d.cold, 2);
  vote('vote_new_second_viewer_cold', v2, d.cold, 0); // post cached now, viewer cold
  vote('vote_new_second_poll_warm', v1, d.cold2, 3); // the viewer is warm, the post is not
  vote('vote_via_repost_id', v3, d.repost, 1); // +2 reads: the REPOST row, then the original
  vote('vote_author_refused', d.author, d.cold, 0);
  vote('vote_choice_out_of_range', v4, d.cold, 9);
  vote('vote_no_poll', v4, d.plain, 0);
  vote('vote_closed', v4, d.short, 0);
  // GetPost
  call('getpost_closed_poll', POSTS, 'GetPost', { postId: d.short }, v4.idToken);
  call('getpost_voter', POSTS, 'GetPost', { postId: d.cold }, v1.idToken);
  call('getpost_nonvoter', POSTS, 'GetPost', { postId: d.cold }, v4.idToken);
  step('end');
}

export function hotPoll(d) {
  if (exec.scenario.iterationInTest === 0) phase('hot_poll');
  const i = exec.scenario.iterationInTest;
  if (i >= HOT_VOTERS) return;
  const v = d.voters[i];
  const res = rpcCall(ENG, 'VotePoll', { idempotencyKey: `w6-hot-${d.run}-${i}-0123456789`, postId: d.hot, choiceIndex: i % 4 }, v, 'VotePoll', { phase: 'hot' });
  if (res.status === 200) voteOk.add(1);
  else if (res.status === 503 || String(res.body).includes('UNAVAILABLE')) voteUnavailable.add(1);
  else voteOther.add(1);
}

export function mixCalls(d) {
  if (exec.scenario.iterationInTest === 0) phase('mix');
  const i = exec.scenario.iterationInTest;
  const pool = d.voters.slice(HOT_VOTERS);
  const poll = d.mix[i % d.mix.length];
  const v = pool[(i * 7) % pool.length];
  let res;
  if (i % 4 === 3) res = rpcCall(POSTS, 'GetPost', { postId: poll }, v, 'GetPost', { phase: 'mix' });
  else res = rpcCall(ENG, 'VotePoll', { idempotencyKey: `w6-mix-${d.run}-${i}-0123456789`, postId: poll, choiceIndex: i % 3 }, v, 'VotePoll', { phase: 'mix' });
  // ALREADY_VOTED (a voter repeating on a poll) and 429 are fine in the mix; anything else is not.
  if (res.status !== 200 && res.status !== 400 && res.status !== 412 && res.status !== 429) mixOther.add(1);
}

export function verifyHot(d) {
  phase('verify');
  const res = rpcCall(POSTS, 'GetPost', { postId: d.hot }, d.author.idToken, 'GetPost', { phase: 'verify' });
  if (res.status !== 200) { console.log(`W6 VERIFY failed: status ${res.status} ${String(res.body).slice(0, 200)}`); return; }
  const poll = res.json('post.post.poll');
  const total = parseInt(poll.totalVotes || '0', 10);
  const sum = (poll.choices || []).reduce((s, c) => s + parseInt(c.votes || '0', 10), 0);
  console.log(`W6 VERIFY hot poll total_votes=${total} choice_sum=${sum} results_visible=${poll.resultsVisible} counts=${(poll.choices || []).map((c) => c.votes || 0).join('/')}`);
}
