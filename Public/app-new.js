/*
 * 새 앱 등록 화면.
 *
 * 파일을 고르지 않으면 그냥 폼이 `POST` 되어 앱만 등록된다. 스크립트가 없을 때와
 * 같은 동작이다. 파일을 고르면 등록과 첫 버전 업로드를 이어서 한다 (ADR-0031).
 *
 *   1. POST /api/v1/apps                      앱을 만든다
 *   2. POST /api/v1/apps/:id/versions         버전을 만들고 올릴 자리를 받는다
 *   3. PUT  <presigned URL>                   스토리지에 직접 올린다
 *   4. POST /api/v1/versions/:id/complete     다 올렸다고 알린다
 *
 * 1번이 성공하고 그 뒤가 실패하면 **앱은 남는다.** 되돌리지 않는다. 그 상태는
 * 파일 없이 등록만 한 것과 같고, 앱 화면에서 버전을 다시 올리면 된다. 화면에
 * 그렇게 안내한다. 되돌리려 들면 "앱을 지웠는데 사실은 안 지워졌다" 같은 더 나쁜
 * 상태가 생긴다.
 */
(function () {
    "use strict";

    var form = document.getElementById("app-new-form");
    var picker = document.getElementById("bundle-picker");
    var input = document.getElementById("bundle-file");
    var status = document.getElementById("bundle-read-status");
    var firstVersion = document.getElementById("first-version");
    var errorBox = document.getElementById("app-new-error");
    var submit = document.getElementById("app-new-submit");
    var progressRow = document.getElementById("app-new-progress");
    var bar = document.getElementById("app-new-bar");
    var progressLabel = document.getElementById("app-new-status");
    if (!form || !picker || !input) return;

    picker.hidden = false;

    input.addEventListener("change", function () {
        firstVersion.hidden = !input.files[0];
        fill().catch(function (error) {
            say("번들에서 값을 읽지 못했습니다. 아래 칸을 직접 채우세요. (" + error.message + ")");
        });
    });

    form.addEventListener("submit", function (event) {
        // 파일을 안 골랐으면 평소대로 폼을 넘긴다. 서버가 등록하고 리다이렉트한다.
        if (!input.files[0]) return;

        event.preventDefault();
        run().catch(function (error) {
            fail(error.message || "등록에 실패했습니다.");
        });
    });

    // MARK: - 등록 + 첫 버전

    async function run() {
        var file = input.files[0];
        requireVersionFields();

        busy(true);
        showError(null);
        progressRow.hidden = false;
        setProgress(0, "앱을 등록하는 중…");

        var app = await createApp();

        var ticket;
        try {
            setProgress(0, "버전을 만드는 중…");
            ticket = await createVersion(app.id);
            await putFile(ticket.uploadURL, file);
            setProgress(100, "마무리하는 중…");
            await completeUpload(ticket.version.id);
        } catch (error) {
            // 앱은 이미 만들어졌다. 그 사실을 숨기면 다시 등록하려다 번들 ID 중복에
            // 막히고, 왜 막히는지 알 수 없다.
            throw new Error(
                error.message + "\n\n" +
                "앱은 등록됐습니다. 파일만 올라가지 않았으니 앱 화면에서 새 버전으로 다시 올리세요: " +
                "/apps/" + app.id
            );
        }

        window.location.href = "/apps/" + app.id;
    }

    /** 파일을 골랐으면 버전 칸도 채워져야 한다. 브라우저 기본 검사는 hidden 칸을 건너뛴다. */
    function requireVersionFields() {
        if (!form.elements.shortVersion.value.trim()) {
            throw new Error("버전을 적으세요.");
        }
        if (!form.elements.buildNumber.value.trim()) {
            throw new Error("빌드 번호를 적으세요.");
        }
    }

    async function createApp() {
        return await postJSON(form.dataset.appsUrl, {
            bundleID: form.elements.bundleID.value.trim(),
            name: form.elements.name.value.trim(),
            summary: emptyToNull(form.elements.summary.value),
            description: emptyToNull(form.elements.description.value),
            category: emptyToNull(form.elements.category.value)
        });
    }

    async function createVersion(appID) {
        return await postJSON(form.dataset.appsUrl + "/" + appID + "/versions", {
            shortVersion: form.elements.shortVersion.value.trim(),
            buildNumber: Number(form.elements.buildNumber.value),
            uploadKind: form.querySelector("input[name=uploadKind]:checked").value,
            releaseNotes: null,
            minimumOSVersion: emptyToNull(form.elements.minimumOSVersion.value),
            entitlements: await readEntitlements()
        });
    }

    async function completeUpload(versionID) {
        await postJSON(form.dataset.versionRoot + "/" + versionID + "/complete", {});
    }

    async function postJSON(url, body) {
        var response = await fetch(url, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            credentials: "same-origin",
            body: JSON.stringify(body)
        });
        if (!response.ok) throw new Error(await reasonOf(response));
        return await response.json().catch(function () { return {}; });
    }

    async function readEntitlements() {
        var field = form.elements.entitlements;
        var file = field && field.files[0];
        if (!file) return null;
        return await file.text();
    }

    /*
     * `fetch` 로는 업로드 진행률을 알 수 없어서 여기만 XMLHttpRequest 를 쓴다.
     * upload.js 와 같은 이유이고 같은 모양이다 (ADR-0012).
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

    // MARK: - 자동 채우기

    async function fill() {
        var file = input.files[0];
        if (!file) {
            say(null);
            return;
        }
        say("번들을 읽는 중…");

        var info = await window.AlleyBundleInfo.read(file);
        var filled = [];
        var kept = [];

        [
            ["bundleID", info.bundleID, "번들 ID"],
            ["name", info.name, "이름"],
            ["shortVersion", info.shortVersion, "버전"],
            ["buildNumber", info.buildNumber, "빌드 번호"],
            ["minimumOSVersion", info.minimumOSVersion, "최소 macOS"]
        ].forEach(function (row) {
            var field = form.elements[row[0]];
            var value = row[1];
            if (!field || !value) return;

            if (row[0] === "buildNumber" && !/^\d+$/.test(value)) {
                kept.push(row[2] + ' 은 번들이 "' + value + '" 라고 적어 숫자로 쓸 수 없습니다');
                return;
            }

            if (isOursToFill(field)) {
                field.value = value;
                field.dataset.filledFromBundle = "1";
                filled.push(row[2] + " " + value);
            } else if (field.value.trim() !== value) {
                kept.push(row[2] + ' 은 번들이 "' + value + '" 라고 적었습니다');
            }
        });

        var lines = [];
        if (filled.length) lines.push("채웠습니다 - " + filled.join(", "));
        if (kept.length) lines.push("적어둔 값을 그대로 뒀습니다 - " + kept.join("; "));
        if (!filled.length && !kept.length) lines.push("번들에서 채울 값이 없었습니다.");
        say(lines.join(" / "));
    }

    /*
     * 이 칸을 우리가 채워도 되는가. upload.js 와 같은 규칙이다.
     *
     * 비어 있거나, 앞서 우리가 채웠거나, 서버가 제안한 값 그대로면 채운다.
     * 마지막 조건이 없으면 빌드 번호가 영영 안 채워진다.
     */
    function isOursToFill(field) {
        if (field.value.trim() === "") return true;
        if (field.dataset.filledFromBundle === "1") return true;
        var suggested = field.dataset.suggested;
        return suggested !== undefined && field.value.trim() === suggested.trim();
    }

    // MARK: - 화면

    function setProgress(percent, text) {
        bar.value = percent;
        progressLabel.textContent = text;
    }

    function busy(isBusy) {
        submit.disabled = isBusy;
        submit.textContent = isBusy ? "등록하는 중…" : "등록";
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

    function say(message) {
        if (!status) return;
        status.hidden = message === null;
        status.textContent = message || "";
    }

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
