#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p DerivedData/Tests
swiftc Shared/TrialAccessRules.swift Tests/TrialAccessSmoke.swift -o DerivedData/Tests/TrialAccessSmoke
DerivedData/Tests/TrialAccessSmoke
python3 - <<'PY'
import json
from pathlib import Path
config = json.loads(Path('TailView.storekit').read_text())
products = {item['productID']: item for item in config['products']}
assert set(products) == {'com.10x.tailview.ios.trial7', 'com.10x.tailview.ios.lifetime'}
assert all(item['type'] == 'NonConsumable' for item in products.values())
assert products['com.10x.tailview.ios.trial7']['displayPrice'] == '0.00'
assert products['com.10x.tailview.ios.lifetime']['displayPrice'] == '9.99'
assert not config['subscriptionGroups'] and not config['nonRenewingSubscriptions']
print('StoreKit configuration checks passed: free trial, 9.99 permanent unlock, no subscriptions')
PY
