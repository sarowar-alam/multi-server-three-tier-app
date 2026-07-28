#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-three-tier-app/main/userdata-setup-scripts/tier3-database.sh -o /tmp/setup-db.sh
bash /tmp/setup-db.sh