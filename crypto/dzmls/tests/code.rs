use dzmls::{MlsError, Party, security_code};

fn party(user: &[u8], keys: &[&[u8]]) -> Party {
    Party {
        user_id: user.to_vec(),
        device_keys: keys.iter().map(|k| k.to_vec()).collect(),
    }
}

fn alice() -> Party {
    party(b"alice", &[&[1u8; 32]])
}

fn bob() -> Party {
    party(b"bob", &[&[2u8; 32]])
}

fn err_code(r: Result<String, MlsError>) -> &'static str {
    r.unwrap_err().code.as_str()
}

#[test]
fn code_is_60_digits_in_12_groups() {
    let code = security_code(&alice(), &bob()).unwrap();
    // ^(\d{5} ){11}\d{5}$ without a regex dependency.
    let groups: Vec<&str> = code.split(' ').collect();
    assert_eq!(groups.len(), 12, "{code}");
    for g in groups {
        assert_eq!(g.len(), 5, "{code}");
        assert!(g.bytes().all(|b| b.is_ascii_digit()), "{code}");
    }
    assert_eq!(code.len(), 71);
}

#[test]
fn code_is_symmetric() {
    assert_eq!(
        security_code(&alice(), &bob()).unwrap(),
        security_code(&bob(), &alice()).unwrap()
    );
}

#[test]
fn code_ignores_key_order_and_duplicates() {
    let k1 = [1u8; 32];
    let k2 = [9u8; 32];
    let base = security_code(&party(b"alice", &[&k1, &k2]), &bob()).unwrap();
    assert_eq!(
        security_code(&party(b"alice", &[&k2, &k1]), &bob()).unwrap(),
        base
    );
    assert_eq!(
        security_code(&party(b"alice", &[&k2, &k1, &k2, &k1]), &bob()).unwrap(),
        base
    );
}

#[test]
fn code_changes_when_a_device_is_added() {
    let one = security_code(&alice(), &bob()).unwrap();
    let two = security_code(&party(b"alice", &[&[1u8; 32], &[3u8; 32]]), &bob()).unwrap();
    assert_ne!(one, two);
    // The other side's half is untouched: bob is "hi" in both, so the last 6 groups agree.
    assert_eq!(
        one.split(' ').skip(6).collect::<Vec<_>>(),
        two.split(' ').skip(6).collect::<Vec<_>>()
    );
    assert_ne!(
        one.split(' ').take(6).collect::<Vec<_>>(),
        two.split(' ').take(6).collect::<Vec<_>>()
    );
}

#[test]
fn code_known_answer() {
    let code = security_code(&alice(), &bob()).unwrap();
    assert_eq!(
        code,
        "01071 07934 45417 07576 54938 95528 17637 75144 80312 08694 94109 81731"
    );
}

#[test]
fn code_rejects_bad_parties() {
    assert_eq!(
        err_code(security_code(&party(b"", &[&[1u8; 32]]), &bob())),
        "bad_input"
    );
    assert_eq!(
        err_code(security_code(&alice(), &party(b"alice", &[&[2u8; 32]]))),
        "bad_input"
    );
    assert_eq!(
        err_code(security_code(&alice(), &party(b"bob", &[]))),
        "bad_input"
    );
}
