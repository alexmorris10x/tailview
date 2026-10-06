#!/usr/bin/env python3
"""Execute the actual identity closure in a pure Swift host harness; no app launch."""
from pathlib import Path
import json
import re
import resource
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = {'path': 'IOSViewer/SavedMacStore.swift', 'property': 'service', 'cases': [('com.10x.tailview.ios', 'com.10x.tailview.ios.saved-macs', 'com.10x.tailview.ios.saved-macs'), ('com.10x.tailview.ios.dev', 'com.10x.tailview.ios.dev.saved-macs', 'com.10x.tailview.ios.dev.saved-macs'), ('MISSING', 'MISSING', None), ('unexpected', 'MISSING', None)]}
source = (ROOT / CONFIG["path"]).read_text()
match = re.search(r"private static let " + CONFIG["property"] + r": String = \{(.*?)\n    \}\(\)", source, re.S)
assert match, "Identity closure not found"
body = match.group(1).replace("Bundle.main", "FixtureBundle.main")
harness = r'''import Foundation
struct FixtureBundle {
    static let main = FixtureBundle()
    var bundleIdentifier: String? { CommandLine.arguments[1] == "MISSING" ? nil : CommandLine.arguments[1] }
    func object(forInfoDictionaryKey key: String) -> Any? {
        let value = CommandLine.arguments[2]
        if value == "MISSING" { return nil }
        if value == "WRONG_TYPE" { return value }
        return [value]
    }
}
let identity: String = {
''' + body + "\n}()\nprint(identity)\n"
compiler = shutil.which("swiftc")
if compiler is None:
    raise SystemExit("BLOCKED: swiftc required; run on the authorized Mac QA executor")
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
with tempfile.TemporaryDirectory(prefix="ios-identity-") as temporary:
    path = Path(temporary)
    (path / "Identity.swift").write_text(harness)
    subprocess.run([compiler, str(path / "Identity.swift"), "-o", str(path / "identity")], check=True)
    for bundle, permission, expected in CONFIG["cases"]:
        result = subprocess.run([str(path / "identity"), bundle, permission], capture_output=True, text=True)
        if expected is None:
            assert result.returncode != 0, (bundle, permission, "must reject configuration")
        else:
            assert result.returncode == 0 and result.stdout.strip() == expected, (bundle, permission, result.stderr)
print("PASS: " + str(len(CONFIG["cases"])) + " actual Swift closure fixtures")
