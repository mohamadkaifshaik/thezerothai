"""End-to-end tests for agentctl, using fake engine CLIs in a throwaway git repository.

Run: python -m unittest discover -s agents/orchestrator/tests -v
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
AGENTCTL = HERE.parent / "agentctl.py"
FAKE = HERE / "fake_agent.py"
REPO_AGENTS = HERE.parent.parent  # <repo>/agents

sys.path.insert(0, str(HERE.parent))
import agentctl  # noqa: E402


def git(root, *args):
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True).stdout.strip()


class AgentctlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agentctl-test-"))
        self.root = self.tmp / "repo"
        self.root.mkdir()
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "config", "user.email", "t@example.com")
        git(self.root, "config", "user.name", "test")
        (self.root / ".gitignore").write_text(".agent_state/*\n!.agent_state/README.md\n")
        (self.root / "README.md").write_text("test repo\n")
        for rel in ("shared/PROTOCOL.md", "claude/INSTRUCTIONS.md", "codex/INSTRUCTIONS.md"):
            dst = self.root / "agents" / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_AGENTS / rel, dst)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "init")

        cfg = json.loads((REPO_AGENTS / "orchestrator.json").read_text(encoding="utf-8"))
        py = sys.executable
        cfg["agents"]["claude"]["command"] = [py, str(FAKE), "claude", "-p"]
        cfg["agents"]["claude"]["resume_command"] = [py, str(FAKE), "claude", "-p", "--resume", "{session_id}"]
        cfg["agents"]["codex"]["command"] = [py, str(FAKE), "codex", "exec", "--json", "-"]
        cfg["agents"]["codex"]["resume_command"] = [py, str(FAKE), "codex", "exec", "resume", "--json",
                                                    "{session_id}", "-"]
        cfg.update({"grace_seconds": 3, "poll_seconds": 0.1, "transient_backoff_seconds": [0]})
        self.cfg_path = self.tmp / "orchestrator.json"
        self.cfg_path.write_text(json.dumps(cfg))
        self.plan = self.tmp / "plan.json"
        self.log = self.tmp / "fakelog"
        self.env = dict(os.environ, AGENTCTL_ROOT=str(self.root), AGENTCTL_CONFIG=str(self.cfg_path),
                        FAKE_PLAN=str(self.plan), FAKE_LOG=str(self.log), PYTHONIOENCODING="utf-8")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # helpers
    def set_plan(self, **plan):
        self.plan.write_text(json.dumps({"claude": [], "codex": [], **plan}))

    def ctl(self, *args, timeout=120):
        return subprocess.run([sys.executable, str(AGENTCTL), *args], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=timeout)

    def session(self):
        return json.loads((self.root / ".agent_state" / "session.json").read_text())

    def calls(self, engine):
        return sorted(self.log.glob(f"{engine}-*.json"), key=lambda p: int(p.stem.split("-")[1]))

    def call(self, engine, i):
        return json.loads((self.log / f"{engine}-{i}.json").read_text())

    # tests
    def test_tool_result_with_429_text_does_not_fail_over(self):
        self.set_plan(claude=["tool429"])
        r = self.ctl("start", "--goal", "read the rate limiter")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        s = self.session()
        self.assertEqual([x["agent"] for x in s["runs"]], ["claude"])
        self.assertEqual(s["runs"][0]["outcome"], "completed")
        self.assertEqual(s["cooldowns"], {})
        self.assertEqual(self.calls("codex"), [])

    def test_limit_fails_over_and_hands_off(self):
        self.set_plan(claude=["limit"], codex=["ok"])
        r = self.ctl("start", "--goal", "build the thing")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        s = self.session()
        self.assertEqual([(x["agent"], x["outcome"]) for x in s["runs"]], [("claude", "limit"), ("codex", "completed")])
        self.assertIn("claude", s["cooldowns"])
        codex_prompt = self.call("codex", 0)["prompt"]
        self.assertIn("# HANDOFF", codex_prompt)
        self.assertIn("work-claude-0.txt", codex_prompt)          # modified files from the dying engine
        self.assertIn("task done by claude #0", codex_prompt)     # its completed task
        self.assertIn("Codex engineering team", codex_prompt)     # the new engine's own instructions
        self.assertTrue(list((self.root / ".agent_state" / "handoffs").glob("*-claude-limit.md")))
        refs = git(self.root, "for-each-ref", "--format=%(refname)", "refs/agent-checkpoints")
        self.assertIn("limit-claude", refs)

    def test_both_limited_exits_75(self):
        self.set_plan(claude=["limit"], codex=["limit"])
        r = self.ctl("start", "--goal", "x")
        self.assertEqual(r.returncode, agentctl.EXIT_BOTH_LIMITED, r.stdout + r.stderr)
        s = self.session()
        self.assertEqual(s["status"], "both_limited")
        self.assertEqual(set(s["cooldowns"]), {"claude", "codex"})
        r = self.ctl("continue")
        self.assertEqual(r.returncode, agentctl.EXIT_BOTH_LIMITED)
        r = self.ctl("recover")
        self.assertEqual(r.returncode, agentctl.EXIT_BOTH_LIMITED)
        self.set_plan(claude=["limit", "ok"], codex=["limit"])
        r = self.ctl("recover", "--clear-cooldowns", "--then-continue")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.session()["runs"][-1]["outcome"], "completed")

    def test_fatal_does_not_fail_over(self):
        self.set_plan(claude=["fatal"])
        r = self.ctl("start", "--goal", "x")
        self.assertEqual(r.returncode, agentctl.EXIT_FATAL, r.stdout + r.stderr)
        s = self.session()
        self.assertEqual(s["status"], "failed")
        self.assertEqual(len(s["runs"]), 1)
        self.assertEqual(self.calls("codex"), [])
        self.assertIn("Invalid API key", (self.root / ".agent_state" / "HANDOFF.md").read_text())

    def test_transient_retries_the_same_engine(self):
        self.set_plan(claude=["transient", "ok"])
        r = self.ctl("start", "--goal", "x")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        s = self.session()
        self.assertEqual([(x["agent"], x["mode"], x["outcome"]) for x in s["runs"]],
                         [("claude", "fresh", "transient"), ("claude", "resume", "completed")])
        self.assertIn("--resume", self.call("claude", 1)["argv"])

    def test_stop_kills_a_hung_run_and_continue_resumes(self):
        self.set_plan(claude=["hang", "ok"])
        proc = subprocess.Popen([sys.executable, str(AGENTCTL), "start", "--goal", "long job"], cwd=self.root,
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        pid_file = self.log / "claude-0.pid"
        for _ in range(200):
            if pid_file.exists():
                break
            time.sleep(0.1)
        self.assertTrue(pid_file.exists(), "the fake engine never started")
        r = self.ctl("stop")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        out, _ = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, agentctl.EXIT_STOPPED, out)
        fake_pid = int(pid_file.read_text())
        time.sleep(0.5)
        self.assertFalse(agentctl.pid_alive(fake_pid), "the engine process outlived the stop")
        self.assertFalse((self.root / ".agent_state" / "agent.lock").exists())
        self.assertEqual(self.session()["status"], "stopped")
        r = self.ctl("continue")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        second = self.call("claude", 1)
        self.assertIn("--resume", second["argv"])                    # native session resumed
        self.assertEqual(self.session()["runs"][-1]["mode"], "resume")

    def start_hang(self):
        self.set_plan(claude=["hang", "ok"])
        proc = subprocess.Popen([sys.executable, str(AGENTCTL), "start", "--goal", "long job"], cwd=self.root,
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        pid_file = self.log / "claude-0.pid"
        for _ in range(200):
            if pid_file.exists():
                break
            time.sleep(0.1)
        self.assertTrue(pid_file.exists(), "the fake engine never started")
        time.sleep(0.5)  # let the orchestrator record the engine pid in the lock
        return proc, int(pid_file.read_text())

    def test_commands_refuse_to_touch_state_during_a_live_run(self):
        proc, fake_pid = self.start_hang()
        progress = (self.root / ".agent_state" / "progress.md").read_bytes()
        self.assertEqual(self.ctl("start", "--force-new", "--goal", "other").returncode, agentctl.EXIT_LOCKED)
        self.assertEqual(self.ctl("continue").returncode, agentctl.EXIT_LOCKED)
        self.assertEqual(self.ctl("recover").returncode, agentctl.EXIT_LOCKED)
        self.assertEqual(self.ctl("end", "--force").returncode, agentctl.EXIT_LOCKED)
        self.assertEqual((self.root / ".agent_state" / "progress.md").read_bytes(), progress)
        self.assertEqual(self.ctl("stop").returncode, 0)
        proc.communicate(timeout=60)
        self.assertFalse(agentctl.pid_alive(fake_pid))

    def test_orphaned_engine_counts_as_live_until_killed(self):
        proc, fake_pid = self.start_hang()
        proc.kill()                      # the orchestrator dies abruptly (terminal closed, laptop slept)
        proc.communicate(timeout=30)
        self.assertTrue(agentctl.pid_alive(fake_pid), "the engine should outlive a hard-killed orchestrator")
        try:
            self.assertEqual(self.ctl("continue").returncode, agentctl.EXIT_LOCKED)
            self.assertEqual(self.ctl("recover").returncode, agentctl.EXIT_LOCKED)
            self.assertEqual(self.calls("claude")[1:], [])       # no second engine was started
            st = self.ctl("status")
            self.assertIn("orchestrator is gone", st.stdout)
            r = self.ctl("recover", "--kill")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            time.sleep(0.5)
            self.assertFalse(agentctl.pid_alive(fake_pid))
            self.assertFalse((self.root / ".agent_state" / "agent.lock").exists())
            self.assertEqual(self.session()["status"], "stopped")
        finally:
            agentctl.kill_pid_tree(fake_pid)

    def test_stop_kills_an_orphaned_engine(self):
        proc, fake_pid = self.start_hang()
        proc.kill()
        proc.communicate(timeout=30)
        try:
            r = self.ctl("stop")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            time.sleep(0.5)
            self.assertFalse(agentctl.pid_alive(fake_pid))
            self.assertEqual(self.session()["status"], "stopped")
            self.assertIn("orphaned engine", (self.root / ".agent_state" / "HANDOFF.md").read_text())
            r = self.ctl("continue")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        finally:
            agentctl.kill_pid_tree(fake_pid)

    def test_recover_clears_a_stale_lock_and_running_state(self):
        self.set_plan(claude=["ok"])
        self.assertEqual(self.ctl("start", "--goal", "x").returncode, 0)
        st = self.root / ".agent_state"
        (st / "agent.lock").write_text(json.dumps({"pid": 999999, "agent": "claude"}))
        s = self.session()
        s["status"] = "running"
        (st / "session.json").write_text(json.dumps(s))
        self.assertEqual(self.ctl("continue").returncode, agentctl.EXIT_LOCKED)
        r = self.ctl("recover")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((st / "agent.lock").exists())
        self.assertEqual(self.session()["status"], "stopped")

    def test_recover_restores_a_corrupt_session_file(self):
        self.set_plan(claude=["ok"])
        self.assertEqual(self.ctl("start", "--goal", "x").returncode, 0)
        (self.root / ".agent_state" / "session.json").write_text("{not json")
        r = self.ctl("recover")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.session()["goal"], "x")

    def test_checkpoint_does_not_touch_index_or_worktree(self):
        self.set_plan(claude=["ok"])
        self.assertEqual(self.ctl("start", "--goal", "x").returncode, 0)
        (self.root / "README.md").write_text("changed\n")
        git(self.root, "add", "README.md")
        (self.root / "README.md").write_text("changed again\n")
        (self.root / "new_untracked.txt").write_text("u\n")
        before = (git(self.root, "status", "--porcelain"), git(self.root, "diff", "--cached"), git(self.root, "diff"))
        self.assertEqual(self.ctl("handoff").returncode, 0)
        after = (git(self.root, "status", "--porcelain"), git(self.root, "diff", "--cached"), git(self.root, "diff"))
        self.assertEqual(before, after)
        ref = self.session()["checkpoints"][-1]["ref"]
        files = git(self.root, "ls-tree", "-r", "--name-only", ref)
        self.assertIn("new_untracked.txt", files)
        self.assertIn(".agent_state/progress.md", files)
        self.assertEqual(git(self.root, "show", f"{ref}:README.md"), "changed again")

    def test_end_writes_a_summary_and_closes_the_session(self):
        self.set_plan(claude=["ok"])
        self.assertEqual(self.ctl("start", "--goal", "x").returncode, 0)
        r = self.ctl("end")
        self.assertEqual(r.returncode, agentctl.EXIT_USAGE)  # the template task is still open
        r = self.ctl("end", "--force", "--prune-checkpoints")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.session()["status"], "ended")
        summaries = list((self.root / ".agent_state" / "sessions").glob("*/SUMMARY.md"))
        self.assertEqual(len(summaries), 1)
        text = summaries[0].read_text()
        self.assertIn("task done by claude #0", text)
        self.assertEqual(git(self.root, "for-each-ref", "refs/agent-checkpoints"), "")
        self.assertEqual(self.ctl("start", "--goal", "next").returncode, 0)  # a new session can start

    def test_unit_classifier_ignores_content_and_reads_errors(self):
        ctx = agentctl.Ctx.__new__(agentctl.Ctx)
        cfg = json.loads((REPO_AGENTS / "orchestrator.json").read_text(encoding="utf-8"))
        ctx.patterns = {k: [agentctl.re.compile(p, agentctl.re.I) for p in v] for k, v in cfg["patterns"].items()}
        w = agentctl.RunWatch(ctx, "claude")
        w.feed(json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "content": "429"}]}}))
        self.assertIsNone(w.error)
        w.feed(json.dumps({"type": "rate_limit_event", "rate_limit_info": {"status": "allowed"}}))
        self.assertIsNone(w.error)
        w.feed(json.dumps({"type": "result", "is_error": True, "result": "Credit balance is too low"}))
        self.assertEqual(w.error.kind, "limit")
        c = agentctl.RunWatch(ctx, "codex")
        c.feed(json.dumps({"type": "error", "message": "stream disconnected: 503"}))
        self.assertEqual(c.error.kind, "transient")
        self.assertIsNotNone(agentctl.parse_reset("try again in 30 minutes"))


if __name__ == "__main__":
    unittest.main()
