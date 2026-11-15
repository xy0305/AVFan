from pathlib import Path
import json, subprocess, tempfile, sys

root = Path(__file__).resolve().parents[1]
swift_path = root / 'AVFan/Services/Pan115Client.swift'
fixture_path = root / 'scripts/115-crypto-fixture.json'
s = swift_path.read_text()
f = json.loads(fixture_path.read_text())
crypto = s[s.index('private enum Pan115Crypto {'):].replace('private enum Pan115Crypto', 'enum Pan115Crypto')
arr = lambda x: '[' + ','.join(map(str, x)) + ']'
test = """
let key: [UInt8] = KEY
precondition(Pan115Crypto.derive(key, 4) == D4)
precondition(Pan115Crypto.derive(key, 12) == D12)
let raw: [UInt8] = INPUT
let transformed = try Pan115Crypto.transform(raw)
precondition(transformed == OUTPUT)
for count in 0...250 {
    let bytes = (0..<count).map { UInt8($0 % 256) }
    precondition(Pan115Crypto.xor(Pan115Crypto.xor(bytes, key), key) == bytes)
}
let encoded = try Pan115Crypto.encode(Data(#"{"pickcode":"fixture"}"#.utf8), key: key)
precondition(Data(base64Encoded: encoded)!.count == 128)
for bad in ["", "!", Data([1,2,3]).base64EncodedString(), Data(repeating: 0, count:128).base64EncodedString()] {
    do { _ = try Pan115Crypto.decode(bad, key: key); fatalError("accepted malformed input") } catch {}
}
print("PASS: Security raw RSA vector, XOR derivation, randomized request, malformed response rejection")
"""
for name, field in [('KEY','key'),('D4','derived4'),('D12','derived12'),('INPUT','rawInput'),('OUTPUT','rawOutput')]:
    test = test.replace(name, arr(f[field]))
# Source contract: cookie keys are AVFan-specific, crypto uses SecRandomCopyBytes.
assert 'avfan.115' in s or 'KeychainStore' in s
assert 'avdb.115' not in s
assert 'SecRandomCopyBytes' in s
player = (root / 'AVFan/Views/Pan115PlayerView.swift').read_text()
assert 'addOfflineTask' in player
assert 'waitUntilPlayable' in player or 'waitOfflineReady' in player
assert 'listOfflineTasks' in player or 'findMatchedVideos' in player
assert 'streamsForVideo' in player or 'originalStream' in player
assert 'KSChromePlayer' in player
print('PASS: AVFan 115 storage isolation and player uses KSPlayer push/wait/play APIs')
with tempfile.TemporaryDirectory() as d:
    p = Path(d) / 'main.swift'
    p.write_text('import Foundation\nimport Security\nenum Pan115Error: Error { case api(String) }\n' + crypto + test)
    subprocess.run(['swift', str(p)], check=True)
