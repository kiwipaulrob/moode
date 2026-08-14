#!/bin/bash
# Reusable verification suite for the moOde SendSpin installer + merged fork.
# Run from the repo root (the git checkout of kiwipaulrob/moode, branch
# sendspin-advanced) — e.g. on CT106 (hermes-dev): /root/moode-sendspin/
#   bash /root/.hermes/skills/media/moode-sendspin/scripts/verify-installer.sh
# Requirements: php-cli, python3, git, bash. (CT106 has php-cli installed Aug 2026.)
# Exits non-zero if any check fails. Expected: all [PASS].
#
# What it verifies:
#   1. installer bash syntax
#   2. installer's embedded python heredoc (worker patch) compiles
#   3. every embedded PHP heredoc is valid PHP (function-aware extraction —
#      see the extraction notes below; PYEOF/SINKEOF = python, systemd units,
#      HTML templates and the moOde template-engine files are skipped)
#   4. merged repo PHP files lint (command/renderer.php, inc/renderer.php, ren-config.php)
#   5. worker.php patch behaviour on 3 variants (r1033, r1024, deployed-Pi copy):
#      fresh insert, exactly-one case, php lint, idempotent re-run, uninstall seds clean
#   6. cfg_system DB seeding idempotency (fresh=5 rows, re-run=5 rows, user values kept)
#   7. installer anchor survival in the merged tree
set -u
# MUST pre-create /tmp/hc: section 2 writes patch_body.py there before section 3
# creates the dir. On a fresh /tmp this otherwise yields 5 spurious FAILs
# (python-compile + worker marker/case) that look like installer breakage.
mkdir -p /tmp/hc
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== 1. Installer shell syntax ==="
bash -n moode-sendspin-installer.sh && ok "bash -n installer" || bad "bash -n"

echo "=== 2. Embedded python heredoc compiles ==="
awk '/^install_worker_php\(\)/,/^}$/' moode-sendspin-installer.sh | sed -n "/python3 << 'PYEOF'/,/^PYEOF/p" | sed '1d;$d' > /tmp/hc/patch_body.py
python3 -m py_compile /tmp/hc/patch_body.py && ok "worker patch python compiles" || bad "python compile"

echo "=== 3. Embedded PHP heredocs are valid PHP (function-aware extraction) ==="
python3 << 'EOF'
import re, subprocess, os
src = open('moode-sendspin-installer.sh').read()
os.makedirs('/tmp/hc', exist_ok=True)
# Split into functions by brace depth (NOT line-based awk: a '}' at column 0
# inside a heredoc terminates a naive range early).
funcs = {}
pos = 0
for m in re.finditer(r'(?m)^([a-z_][a-z0-9_]*)\\(\\) \\{$', src):
    name = m.group(1); start = m.end()
    depth = 1; i = start
    while i < len(src) and depth > 0:
        c = src[i]
        if c == '{': depth += 1
        elif c == '}': depth -= 1
        i += 1
    funcs[name] = src[start:i-1]
results = []
for fname, body in funcs.items():
    # heredoc open must be matched with re.MULTILINE (^ / $ line anchors)
    for hm in re.finditer(r"<< '([A-Z0-9_]+)'\n(.*?)^\1$", body, re.S | re.M):
        delim, content = hm.group(1), hm.group(2)
        if delim in ('PYEOF', 'SINKEOF'):
            continue  # python
        if 'Environment=' in content and 'ExecStart' in content:
            continue  # systemd unit
        if 'INSERT INTO' in content or 'CREATE TABLE' in content or 'sqlite3' in content:
            continue  # SQL (DB seeding heredocs are not PHP)
        if '<div' in content or '<form' in content:
            results.append((fname, delim, 'html-template (skipped: moOde template engine)', 0))
            continue
        if 'Setup Guide for SendSpin' in content or content.startswith('#') and 'OVERVIEW' in content:
            results.append((fname, delim, 'plain-text doc (skipped)', 0))
            continue
        fn = f'/tmp/hc/heredoc-{fname}-{delim}.php'
        open(fn, 'w').write('<?php\n' + content)
        r = subprocess.run(['php', '-l', fn], capture_output=True, text=True)
        results.append((fname, delim, 'OK' if r.returncode == 0 else 'FAIL', r.returncode))
for fname, delim, verdict, rc in results:
    print(f'  [{"PASS" if verdict=="OK" else "SKIP" if "skipped" in verdict else "FAIL"}] {fname} ({delim}): {verdict}')
    if rc != 0 and not verdict.startswith('html'):
        raise SystemExit(1)
EOF
[ $? -eq 0 ] && ok "all embedded PHP heredocs lint" || bad "embedded PHP heredoc lint"

echo "=== 4. Merged repo PHP files lint ==="
for f in www/command/renderer.php www/inc/renderer.php www/ren-config.php; do
    php -l "$f" >/dev/null 2>&1 && ok "php -l $f" || bad "php -l $f: $(php -l "$f" 2>&1 | tail -1)"
done

echo "=== 5. Worker patch tests (fresh insert / idempotency / uninstall / legacy) ==="
WORK=/tmp/wpt; mkdir -p $WORK
cat > $WORK/run_patch.py << 'EOF'
import sys
target = sys.argv[1]
src = open('/tmp/hc/patch_body.py').read().replace('/tmp/worker_sendspin_patch.php', target)
exec(compile(src, 'pb', 'exec'), {})
EOF
git show HEAD:www/daemon/worker.php > $WORK/v_r1033.php
git show r1024:www/daemon/worker.php > $WORK/v_r1024.php 2>/dev/null || echo "  (r1024 tag unavailable - skipping that variant)"
# Optional: copy the deployed Pi worker.php to /tmp/hc/worker_pi.php to test the
# real repair scenario (cases present, startup block missing).
[ -f /tmp/hc/worker_pi.php ] && cp /tmp/hc/worker_pi.php $WORK/v_pi.php
for v in r1033 r1024 pi; do
    f="$WORK/v_$v.php"; [ -f "$f" ] || continue
    cp "$f" "$WORK/t_$v.php"
    python3 $WORK/run_patch.py "$WORK/t_$v.php" >/dev/null 2>&1
    [ "$(grep -c 'SendSpin renderer startup' $WORK/t_$v.php)" = "1" ] && ok "$v: marker inserted" || bad "$v: marker"
    [ "$(grep -c "case 'sendspinsvc':" $WORK/t_$v.php)" = "1" ] && ok "$v: case once" || bad "$v: case"
    php -l "$WORK/t_$v.php" >/dev/null 2>&1 && ok "$v: patched php -l" || bad "$v: patched lint"
    cp "$WORK/t_$v.php" "$WORK/t2_$v.php"
    python3 $WORK/run_patch.py "$WORK/t2_$v.php" >/dev/null 2>&1
    diff -q "$WORK/t_$v.php" "$WORK/t2_$v.php" >/dev/null && ok "$v: idempotent" || bad "$v: NOT idempotent"
    cp "$WORK/t_$v.php" "$WORK/u_$v.php"
    # uninstall seds (mirror installer v4.1.1+): new marker + legacy marker + cases
    sed -i '/\/\/ SendSpin renderer startup/,/^\t}$/d' $WORK/u_$v.php 2>/dev/null || true
    sed -i '/\/\/ SendSpin$/,/^\t}$/d' $WORK/u_$v.php 2>/dev/null || true
    sed -i "/case 'sendspinsvc':/,/break;/d" $WORK/u_$v.php 2>/dev/null || true
    sed -i "/case 'sendspinrestart':/,/break;/d" $WORK/u_$v.php 2>/dev/null || true
    [ "$(grep -c sendspinsvc $WORK/u_$v.php)" = "0" ] && ok "$v: uninstall clean" || bad "$v: uninstall leftover"
    php -l "$WORK/u_$v.php" >/dev/null 2>&1 && ok "$v: uninstalled lint" || bad "$v: uninstalled lint"
done

echo "=== 6. DB seeding idempotency (cfg_system has NO unique constraint) ==="
python3 << 'EOF'
import sqlite3, re
src = open('moode-sendspin-installer.sh').read()
m = re.search(r'install_database_entries_full\(\) \{(.*?)^\}$', src, re.S | re.M)
body = m.group(1)
hm = re.search(r"<< 'EOF'\n(.*?)^EOF$", body, re.S | re.M)
sql = [l for l in hm.group(1).splitlines() if 'INSERT INTO cfg_system' in l]
assert len(sql) == 5, f'expected 5 seed inserts, got {len(sql)}'
db = sqlite3.connect(':memory:')
db.execute('CREATE TABLE cfg_system (id INTEGER PRIMARY KEY, param CHAR(32), value CHAR(128))')
for s in sql: db.execute(s)
c1 = db.execute('SELECT count(*) FROM cfg_system').fetchone()[0]
for s in sql: db.execute(s)
c2 = db.execute('SELECT count(*) FROM cfg_system').fetchone()[0]
db.execute("UPDATE cfg_system SET value='1' WHERE param='sendspinsvc'")
for s in sql: db.execute(s)
v = db.execute("SELECT value FROM cfg_system WHERE param='sendspinsvc'").fetchone()[0]
ok = c1 == 5 and c2 == 5 and v == '1'
print(f'  [{"PASS" if ok else "FAIL"}] seed fresh={c1} re-run={c2} user value={v}')
raise SystemExit(0 if ok else 1)
EOF
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo "=== 7. Anchor survival ==="
grep -q "worker: RoonBridge:      ' . \$status" www/daemon/worker.php && ok "RoonBridge log anchor" || bad "RoonBridge anchor"
grep -q "case 'rbrestart':" www/daemon/worker.php && ok "case rbrestart" || bad "rbrestart"
grep -q "_feat_roonbridge" www/templates/ren-config.html && ok "ren-config anchor" || bad "ren-config anchor"
grep -q "FEAT_SENDSPIN" www/inc/constants.php && grep -q "SENDSPINMETA_FILE" www/inc/constants.php && ok "constants" || bad "constants"
grep -c "sendspinsvc\|startSendspin" www/daemon/worker.php | grep -q "^0$" && ok "repo worker clean" || bad "repo worker has sendspin"
grep -q "sendspin-display.js" www/footer.php && ok "footer tag" || bad "footer tag"

echo "=== 8. Upgrade-path regression checks (v4.1.5) ==="
# F2: cfg_sendspin CREATE TABLE must carry UNIQUE on param so INSERT OR IGNORE
# dedupes on fresh installs (was: plain CHAR(32) -> duplicate rows per re-run)
UNIQ=$(grep -c "param TEXT UNIQUE NOT NULL" moode-sendspin-installer.sh)
[ "$UNIQ" = "2" ] && ok "cfg_sendspin CREATE TABLE has UNIQUE (x2)" || bad "cfg_sendspin UNIQUE: found $UNIQ (expect 2)"
python3 << 'EOF'
import sqlite3, re
src = open('moode-sendspin-installer.sh').read()
# pull the 4 INSERT OR IGNORE cfg_sendspin seed lines
m = re.search(r'install_database_entries_full\(\) \{(.*?)^\}$', src, re.S | re.M)
body = m.group(1)
hm = re.search(r"<< 'EOF'\n(.*?)^EOF$", body, re.S | re.M)
seeds = [l for l in hm.group(1).splitlines() if 'INSERT OR IGNORE INTO cfg_sendspin' in l]
assert len(seeds) == 4, f'expected 4 cfg_sendspin seeds, got {len(seeds)}'
db = sqlite3.connect(':memory:')
# recreate EXACTLY the installer's table DDL (must include UNIQUE now)
db.execute('CREATE TABLE IF NOT EXISTS cfg_sendspin (id INTEGER PRIMARY KEY, param TEXT UNIQUE NOT NULL, value CHAR (128))')
for s in seeds: db.execute(s)
c1 = db.execute('SELECT count(*) FROM cfg_sendspin').fetchone()[0]
for s in seeds: db.execute(s)
c2 = db.execute('SELECT count(*) FROM cfg_sendspin').fetchone()[0]
ok = c1 == 4 and c2 == 4
print(f'  [{"PASS" if ok else "FAIL"}] cfg_sendspin fresh={c1} re-run={c2} (must stay 4)')
raise SystemExit(0 if ok else 1)
EOF
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
# F1: install_regenerate_service must be full-mode-only (minimal mode never
# installs the commandw hooks the regenerated unit references)
REGEN_GUARD=$(awk '/# Regenerate service file/,/^    fi$/' moode-sendspin-installer.sh | grep -c 'if \[\[ "\$INSTALL_MODE" == "full" \]\]')
[ "$REGEN_GUARD" = "1" ] && ok "regenerate service guarded to full mode" || bad "regenerate guard: found $REGEN_GUARD (expect 1)"
# F3: install_commandw_scripts must return 0/1 explicitly, not exec $all_ok
if grep -qE '^\s+\$all_ok$' moode-sendspin-installer.sh; then
    bad "stray \$all_ok command-execution return"
else
    grep -q 'return 0' moode-sendspin-installer.sh && ok "no \$all_ok command execution (explicit returns)" || bad "no explicit returns found"
fi

echo ""
echo "========== RESULT: $PASS passed, $FAIL failed =========="
exit $FAIL
