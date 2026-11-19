import Foundation

let key = Chord(label: "⇧⌘L")!
let proof = RestoreQualification(chord: key, targets: ["iMac:backlight", "Kado:gamma"])
let persisted = try JSONDecoder().decode(RestoreQualification.self, from: JSONEncoder().encode(proof))

precondition(shortcutTestSeconds == 3)
precondition(proof.confirms(current: persisted, fromShortcut: true, remaining: 0.1, fullyRestored: true))
precondition(!proof.confirms(current: persisted, fromShortcut: false, remaining: 2, fullyRestored: true))
precondition(!proof.confirms(current: persisted, fromShortcut: true, remaining: 0, fullyRestored: true))
precondition(!proof.confirms(current: persisted, fromShortcut: true, remaining: 2, fullyRestored: false))
precondition(!proof.confirms(current: nil, fromShortcut: true, remaining: 2, fullyRestored: true))
for changed in [
    RestoreQualification(chord: key, targets: ["iMac:backlight"]),
    RestoreQualification(chord: key, targets: ["iMac:gamma", "Kado:gamma"]),
    RestoreQualification(chord: Chord(label: "⇧⌘K")!, targets: proof.targets)
] {
    precondition(!proof.confirms(current: changed, fromShortcut: true, remaining: 2, fullyRestored: true))
}
print("Restore qualification checks passed")
