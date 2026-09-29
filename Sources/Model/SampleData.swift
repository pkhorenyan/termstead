import Foundation

extension SessionStore {
    /// The tree the reference mockup ships with. Its addresses are made up;
    /// it exists for development and screenshots, reachable from the Debug menu.
    static func sample() -> SessionStore {
        let sessions: [String: Session] = [
            "prod-web-01": Session(id: "prod-web-01", user: "deploy", host: "10.0.1.12", port: 22,
                                   icon: .globe),
            "db-primary": Session(id: "db-primary", user: "postgres", host: "10.0.2.5", port: 22,
                                  icon: .database,
                                  jumps: [JumpHost(host: "bastion-01")]),
            "prod-web-02": Session(id: "prod-web-02", user: "deploy", host: "10.0.1.13", port: 22,
                                   icon: .server,
                                   jumps: [JumpHost(host: "bastion-01",
                                                    auth: .key,
                                                    keyPath: "~/.ssh/id_ed25519_bastion"),
                                           JumpHost(host: "nat-gw")]),
            "staging-app": Session(id: "staging-app", user: "ubuntu", host: "stage.internal", port: 22,
                                   icon: .container),
            "raspberry-pi": Session(id: "raspberry-pi", user: "pi", host: "192.168.1.40", port: 22,
                                    icon: .chip),
            // No color: Pavel wants nas left plain.
            "nas": Session(id: "nas", user: "admin", host: "nas.local", port: 2222,
                           icon: .drive),
        ]

        let tree: [SessionGroup] = [
            SessionGroup(id: "production", name: "Production", colorID: nil, children: [
                .group(SessionGroup(id: "web", name: "Web", colorID: "red", children: [
                    .session("prod-web-01"),
                    .group(SessionGroup(id: "canary", name: "Canary", colorID: "orange", children: [
                        .session("prod-web-02"),
                    ])),
                ])),
                .group(SessionGroup(id: "db", name: "Databases", colorID: "violet", children: [
                    .session("db-primary"),
                ])),
            ]),
            SessionGroup(id: "staging", name: "Staging", colorID: nil, children: [
                .session("staging-app"),
            ]),
            SessionGroup(id: "home", name: "Home", colorID: nil, children: [
                .group(SessionGroup(id: "lab", name: "Lab", colorID: "mint", children: [
                    .session("raspberry-pi"),
                ])),
                .session("nas"),
            ]),
        ]

        let lab = testLab()
        let store = SessionStore(
            tree: tree + [lab.group],
            sessions: sessions.merging(lab.sessions.map { ($0.id, $0) }) { first, _ in first },
            selectedID: "prod-web-01",
            pinnedIDs: ["prod-web-01", "db-primary"]
        )
        store.collapsedGroupIDs = ["lab"]
        return store
    }

    /// Sessions for the Docker test lab in `TestLab/` (`./lab.sh up`), which
    /// unlike the rest of the sample data can really be connected to. User
    /// `lab`, password `lab`, key `~/.ssh/termstead-lab`.
    ///
    ///     127.0.0.1:2201 ─▶ direct
    ///     127.0.0.1:2202 ─▶ bastion ─▶ app              (lab-app-1-jump)
    ///                     bastion ─▶ middle ─▶ db     (lab-db-2-jumps, …-typed)
    static func testLab() -> (group: SessionGroup, sessions: [Session]) {
        let key = "~/.ssh/termstead-lab"
        let sessions = [
            Session(id: "lab-direct", user: "lab", host: "127.0.0.1", port: 2201,
                    icon: .server, auth: .key, keyPath: key),
            Session(id: "lab-direct-password", user: "lab", host: "127.0.0.1", port: 2201,
                    icon: .terminal, auth: .password, keyPath: key),
            Session(id: "lab-direct-passphrase", user: "lab", host: "127.0.0.1", port: 2201,
                    icon: .monitor, auth: .key, keyPath: "~/.ssh/termstead-lab-passphrase"),
            Session(id: "lab-bastion", user: "lab", host: "127.0.0.1", port: 2202,
                    icon: .shield, auth: .key, keyPath: key),
            // One jump, named after the saved bastion session.
            Session(id: "lab-app-1-jump", user: "lab", host: "app", port: 22,
                    icon: .globe, auth: .key, keyPath: key,
                    jumps: [JumpHost(host: "lab-bastion")]),
            // Two jumps: the saved bastion, then middle with the target's key.
            Session(id: "lab-db-2-jumps", user: "lab", host: "db", port: 22,
                    icon: .database, auth: .key, keyPath: key,
                    jumps: [JumpHost(host: "lab-bastion"), JumpHost(host: "middle", user: "lab")]),
            // The same two jumps, typed out rather than borrowed from a session.
            Session(id: "lab-db-2-jumps-typed", user: "lab", host: "db", port: 22,
                    icon: .database, auth: .key, keyPath: key,
                    jumps: [JumpHost(host: "127.0.0.1", user: "lab", port: 2202, auth: .key, keyPath: key),
                            JumpHost(host: "middle", user: "lab", port: 22, auth: .key, keyPath: key)]),
            // Passwords at every step: the jump host's and the target's.
            Session(id: "lab-app-password", user: "lab", host: "app", port: 22,
                    icon: .cloud, auth: .password, keyPath: key,
                    jumps: [JumpHost(host: "127.0.0.1", user: "lab", port: 2202, auth: .password)]),
        ]
        let group = SessionGroup(id: "testlab", name: "Test lab", colorID: nil, children: [
            .group(SessionGroup(id: "testlab-direct", name: "Direct", colorID: "mint", children: [
                .session("lab-direct"), .session("lab-direct-password"), .session("lab-direct-passphrase"),
            ])),
            .group(SessionGroup(id: "testlab-jump", name: "Through jump hosts", colorID: "blue", children: [
                .session("lab-bastion"), .session("lab-app-1-jump"), .session("lab-db-2-jumps"),
                .session("lab-db-2-jumps-typed"), .session("lab-app-password"),
            ])),
        ])
        return (group, sessions)
    }
}
