/*
 * 버전 업로드 화면의 세 단계.
 *
 *   1. 서버에 버전을 만들고 올릴 자리(presigned URL)를 받는다
 *   2. 그 URL 로 파일을 스토리지에 직접 PUT 한다
 *   3. 다 올렸다고 서버에 알린다
 *
 * 바이너리가 서버를 거치지 않는 이유는 ADR-0009 에, 이 화면만 스크립트를 쓰는
 * 이유는 ADR-0012 에 있습니다.
 *
 * 빌드 스텝 없이 브라우저가 그대로 읽습니다. 번들러도 프레임워크도 쓰지 않습니다.
 */
(function () {
    "use strict";

    var form = document.getElementById("upload-form");
    if (!form) return;

    var submit = document.getElementById("upload-submit");
    var errorBox = document.getElementById("upload-error");
    var progressRow = document.getElementById("upload-progress");
    var bar = document.getElementById("upload-bar");
    var status = document.getElementById("upload-status");

    form.addEventListener("submit", function (event) {
        event.preventDefault();
        start().catch(function (error) {
            fail(error.message || "업로드에 실패했습니다.");
        });
    });

    var readStatus = document.getElementById("bundle-read-status");
    form.elements.file.addEventListener("change", function () {
        fillFromBundle().catch(function (error) {
            // 자동 채우기가 실패해도 업로드는 그대로 할 수 있다. 오류 상자가 아니라
            // 그 칸 아래 설명으로 알린다. 빨간 배너를 띄우면 올리지 말라는 뜻으로 읽힌다.
            say("번들에서 값을 읽지 못했습니다. 직접 입력하세요. (" + error.message + ")");
        });
    });

    /*
     * 고른 zip 의 Info.plist 로 버전·빌드·최소 macOS 를 채운다.
     *
     * **사람이 이미 적은 값은 건드리지 않는다.** 되돌릴 수 없는 것에 손대지 않는
     * 편이 낫다. 번들의 값이 그 칸과 다르면 덮어쓰는 대신 무엇이 다른지 알린다.
     * 일부러 다르게 적는 경우가 있는데(핫픽스 빌드 번호), 그걸 조용히 되돌리면
     * 올린 사람은 자기가 적은 값이 사라진 것을 모른다.
     */
    async function fillFromBundle() {
        var file = form.elements.file.files[0];
        if (!file) {
            say(null);
            return;
        }
        say("번들을 읽는 중…");

        var info = await window.AlleyBundleInfo.read(file);
        var filled = [];
        var differs = [];

        [
            ["shortVersion", info.shortVersion, "버전"],
            ["buildNumber", info.buildNumber, "빌드 번호"],
            ["minimumOSVersion", info.minimumOSVersion, "최소 macOS"]
        ].forEach(function (row) {
            var field = form.elements[row[0]];
            var value = row[1];
            if (!field || !value) return;

            // 빌드 번호는 서버가 정수로 받는다. 번들이 "0.7.10" 처럼 적어두는 일이
            // 흔해서, 숫자로 읽히지 않으면 채우지 않고 사람에게 맡긴다.
            if (row[0] === "buildNumber" && !/^\d+$/.test(value)) {
                differs.push(row[2] + ' 은 번들이 "' + value + '" 라고 적어 숫자로 쓸 수 없습니다');
                return;
            }

            if (isOursToFill(field)) {
                field.value = value;
                field.dataset.filledFromBundle = "1";
                filled.push(row[2] + " " + value);
            } else if (field.value.trim() !== value) {
                differs.push(row[2] + ' 은 번들이 "' + value + '" 라고 적었습니다');
            }
        });

        var lines = [];
        if (info.bundleID) lines.push("번들 ID: " + info.bundleID);
        if (filled.length) lines.push("채웠습니다 - " + filled.join(", "));
        if (differs.length) lines.push("적어둔 값을 그대로 뒀습니다 - " + differs.join("; "));
        say(lines.length ? lines.join(" / ") : "번들에서 채울 값이 없었습니다.");
    }

    /*
     * 이 칸을 우리가 채워도 되는가.
     *
     * 셋 중 하나면 된다. 비어 있거나, 앞서 우리가 채운 것이거나, **서버가 제안한
     * 값 그대로** 인 경우다.
     *
     * 마지막 조건이 없으면 빌드 번호가 영영 안 채워진다. 그 칸은 서버가 다음 번호를
     * 미리 넣어두는데(`suggestedBuildNumber`), 그것을 사람이 적은 값으로 착각해서
     * 지켜버렸다. 실제로 브라우저로 돌려보고서야 나왔다.
     */
    function isOursToFill(field) {
        if (field.value.trim() === "") return true;
        if (field.dataset.filledFromBundle === "1") return true;
        var suggested = field.dataset.suggested;
        return suggested !== undefined && field.value.trim() === suggested.trim();
    }

    function say(message) {
        if (!readStatus) return;
        readStatus.hidden = message === null;
        readStatus.textContent = message || "";
    }

    async function start() {
        var file = form.elements.file.files[0];
        if (!file) {
            fail("올릴 파일을 고르세요.");
            return;
        }

        busy(true);
        showError(null);
        progressRow.hidden = false;
        setProgress(0, "버전을 만드는 중…");

        var ticket = await createVersion(file);
        setProgress(0, "올리는 중…");
        await putFile(ticket.uploadURL, file);

        setProgress(100, "마무리하는 중…");
        await completeUpload(ticket.version.id);

        // 상세 화면이 새 버전을 상태와 함께 보여준다. 여기서 결과를 다시 그릴 이유가 없다.
        window.location.href = form.dataset.appUrl;
    }

    async function createVersion(file) {
        var body = {
            shortVersion: form.elements.shortVersion.value,
            buildNumber: Number(form.elements.buildNumber.value),
            releaseNotes: emptyToNull(form.elements.releaseNotes.value),
            minimumOSVersion: emptyToNull(form.elements.minimumOSVersion.value),
            // entitlements 는 보통 1KB 도 되지 않아 요청 본문에 그대로 싣는다.
            // 이것 하나 때문에 presigned 세 단계를 또 만들 이유가 없다 (ADR-0016 의 선례).
            entitlements: await readEntitlements()
        };

        var response = await fetch(form.dataset.createUrl, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            // 인증은 세션 쿠키로 한다. 브라우저가 알아서 붙이지만 명시해 둔다.
            credentials: "same-origin",
            body: JSON.stringify(body)
        });
        if (!response.ok) throw new Error(await reasonOf(response));
        return await response.json();
    }

    /*
     * 고른 entitlements plist 를 텍스트로 읽는다. 안 골랐으면 null 이다.
     *
     * 형식 검사는 서버가 한다. 여기서 한 번 더 하면 같은 규칙이 두 군데 살게 되고,
     * 브라우저 쪽만 낡는다.
     */
    async function readEntitlements() {
        var input = form.elements.entitlements;
        var file = input && input.files[0];
        if (!file) return null;
        return await file.text();
    }

    /*
     * fetch 로는 업로드 진행률을 알 수 없어서 여기만 XMLHttpRequest 를 쓴다.
     * 수백 MB 짜리 앱을 올리면서 아무 표시가 없으면 멈춘 것과 구분되지 않는다.
     */
    function putFile(url, file) {
        return new Promise(function (resolve, reject) {
            var request = new XMLHttpRequest();
            request.open("PUT", url);

            request.upload.addEventListener("progress", function (event) {
                if (!event.lengthComputable) return;
                var percent = Math.round((event.loaded / event.total) * 100);
                setProgress(percent, "올리는 중… " + percent + "%");
            });

            request.addEventListener("load", function () {
                if (request.status >= 200 && request.status < 300) {
                    resolve();
                } else {
                    reject(new Error("스토리지가 업로드를 거부했습니다 (" + request.status + ")."));
                }
            });
            request.addEventListener("error", function () {
                reject(new Error("스토리지에 연결하지 못했습니다. 네트워크를 확인하세요."));
            });
            request.addEventListener("abort", function () {
                reject(new Error("업로드가 중단됐습니다."));
            });

            request.send(file);
        });
    }

    async function completeUpload(versionID) {
        var response = await fetch(form.dataset.versionRoot + "/" + versionID + "/complete", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            credentials: "same-origin",
            // 해시는 보내지 않는다. 브라우저에는 파일을 통째로 메모리에 올리지 않고
            // SHA-256 을 계산할 방법이 없다 (ADR-0012).
            body: "{}"
        });
        if (!response.ok) throw new Error(await reasonOf(response));
    }

    // MARK: - 화면

    function setProgress(percent, text) {
        bar.value = percent;
        status.textContent = text;
    }

    function busy(isBusy) {
        submit.disabled = isBusy;
        submit.textContent = isBusy ? "올리는 중…" : "올리기";
    }

    function fail(message) {
        busy(false);
        progressRow.hidden = true;
        showError(message);
    }

    function showError(message) {
        errorBox.hidden = message === null;
        errorBox.textContent = message || "";
    }

    // MARK: - 보조

    /** 서버가 준 사람이 읽는 실패 이유. 형식이 다르면 상태 코드라도 보여준다. */
    async function reasonOf(response) {
        try {
            var payload = await response.json();
            if (payload && payload.reason) return payload.reason;
        } catch (error) {
            // 아래 기본 문장으로 떨어진다.
        }
        return "요청이 실패했습니다 (" + response.status + ").";
    }

    function emptyToNull(value) {
        var trimmed = (value || "").trim();
        return trimmed === "" ? null : trimmed;
    }
})();
