#!/usr/bin/env python3
"""실제 GitHub·키체인 없이 로컬 배포 명령의 실패·재시도·게시 흐름을 검증한다."""

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

project = Path(__file__).resolve().parent.parent


def run(*args, cwd, env=None, success=True):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if success and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix="codexswitch-release-test-") as directory:
    root = Path(directory)
    remote, repo, tools = root / "remote.git", root / "repo", root / "tools"
    run("git", "init", "--bare", "--initial-branch=main", str(remote), cwd=root)
    run("git", "clone", str(remote), str(repo), cwd=root)
    run("git", "config", "user.name", "Release Test", cwd=repo)
    run("git", "config", "user.email", "release@example.com", cwd=repo)
    for name in ["scripts", "Resources", "docs/releases"]:
        (repo / name).mkdir(parents=True)
    for name in ["release.sh", "prepare-release.py", "test-prepare-release.py"]:
        shutil.copy(project / "scripts" / name, repo / "scripts" / name)
    (repo / "Resources/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleShortVersionString": "0.3.10", "CFBundleVersion": "14",
    }))
    (repo / "docs/releases/0.3.11.md").write_text("Test release notes\n")
    # 패키징만 대체하고 버전 기록과 push는 실제 임시 Git 저장소로 확인한다.
    (repo / "scripts/package-release.sh").write_text('''#!/bin/bash
set -euo pipefail
[[ "${FAIL_PACKAGE:-0}" != 1 ]] || exit 7
mkdir -p dist/CodexSwitch.app/Contents
cp Resources/Info.plist dist/CodexSwitch.app/Contents/Info.plist
printf 'test archive' > dist/CodexSwitch-0.3.11-macos-arm64.zip
printf 'test feed' > dist/appcast.xml
''')
    (repo / "scripts/package-release.sh").chmod(0o755)
    (repo / ".gitignore").write_text("dist/\n")
    run("git", "add", ".", cwd=repo)
    run("git", "commit", "-m", "Release fixture", cwd=repo)
    run("git", "tag", "v0.3.10", cwd=repo)
    run("git", "push", "origin", "main", "v0.3.10", cwd=repo)
    original = (repo / "Resources/Info.plist").read_bytes()
    # 참고 이미지 폴더는 앱 빌드에 섞이지 않으며 배포를 막지 않는다.
    (repo / "output").mkdir()
    (repo / "output/preview.txt").write_text("local preview")
    tools.mkdir()
    (tools / "git").write_text('''#!/bin/bash
if [[ "$*" == "remote get-url origin" ]]; then
    echo https://github.com/heeeete/CodexSwitch.git
else
    exec /usr/bin/git "$@"
fi
''')
    (tools / "gh").write_text('''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ["RELEASE_TEST_ROOT"])
state_file = root / "release.json"
state = json.loads(state_file.read_text()) if state_file.exists() else None
if args[:2] == ["auth", "status"]:
    sys.exit(0)
command = args[1]
if command == "list":
    if state is not None:
        print(str(state["isDraft"]).lower())
elif command == "create":
    assert "--draft" in args and "--notes-file" in args
    state = {"isDraft": True}
elif command == "edit":
    if "--draft=false" in args:
        assert (root / "downloaded").exists()
        state["isDraft"] = False
elif command == "upload":
    (root / "assets").mkdir(exist_ok=True)
    for name in ["CodexSwitch-0.3.11-macos-arm64.zip", "appcast.xml"]:
        shutil.copy(Path("dist") / name, root / "assets" / name)
elif command == "download":
    if os.environ.get("FAIL_DOWNLOAD") == "1":
        sys.exit(8)
    target = Path(args[args.index("--dir") + 1])
    for asset in (root / "assets").iterdir():
        shutil.copy(asset, target / asset.name)
    (root / "downloaded").touch()
elif command == "view":
    print("https://example.invalid/releases/v0.3.11")
else:
    raise AssertionError(args)
if state is not None:
    state_file.write_text(json.dumps(state))
''')
    for tool in tools.iterdir():
        tool.chmod(0o755)
    env = {**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"], "RELEASE_TEST_ROOT": str(root)}

    # 빌드 실패 시 버전과 원격 태그를 그대로 유지한다.
    failed = run("bash", "scripts/release.sh", "0.3.11", cwd=repo, env={**env, "FAIL_PACKAGE": "1"}, success=False)
    assert failed.returncode == 7, failed.stdout + failed.stderr
    assert (repo / "Resources/Info.plist").read_bytes() == original
    assert not (root / "release.json").exists()

    # 업로드 뒤 검증 실패는 초안을 남기며, 같은 명령으로 빌드 번호 증가 없이 재시도한다.
    failed = run("bash", "scripts/release.sh", "0.3.11", cwd=repo, env={**env, "FAIL_DOWNLOAD": "1"}, success=False)
    assert failed.returncode == 8, failed.stdout + failed.stderr
    release_commit = run("git", "rev-parse", "HEAD", cwd=repo).stdout
    assert json.loads((root / "release.json").read_text())["isDraft"]
    run("bash", "scripts/release.sh", "0.3.11", cwd=repo, env=env)
    assert run("git", "rev-parse", "HEAD", cwd=repo).stdout == release_commit
    assert run("git", "rev-parse", "refs/tags/v0.3.11", cwd=remote).stdout == release_commit
    assert not json.loads((root / "release.json").read_text())["isDraft"]
    assert not (repo / "dist/CodexSwitch.app").exists()
    info = plistlib.loads((repo / "dist/local-test/CodexSwitch.app/Contents/Info.plist").read_bytes())
    assert info["CFBundleVersion"] == "15"
    assert run("bash", "scripts/release.sh", "0.3.11", cwd=repo, env=env, success=False).returncode != 0

print("Local release failure, retry, publication and latest app checks passed")
