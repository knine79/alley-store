/*
 * 새 앱 등록. 두 단계다 (ADR-0033).
 *
 *   1단계  파일을 끌어다 놓는다. 다른 입력은 없다
 *   2단계  값을 확인하고 모자란 것을 채운다
 *
 * zip 이면 1단계에서 번들을 열어 다섯 칸을 채운 뒤 2단계로 넘긴다. dmg 는 브라우저가
 * 열 수 없어서 번들 ID 만 받고, 버전과 최소 macOS 는 올린 뒤 서명 워커가 번들에서
 * 읽어 서버가 채운다.
 *
 * **스크립트가 없으면 1단계가 아예 없다.** 2단계 폼이 드러나 있고 그것을 `POST` 하면
 * 앱만 등록된다. 그래서 1단계는 HTML 에서 `hidden` 이고 여기서 벗긴다.
 *
 * 등록 흐름은 네 요청이다.
 *
 *   1. POST /api/v1/apps                    앱을 만든다
 *   2. POST /api/v1/apps/:id/versions       버전을 만들고 올릴 자리를 받는다
 *   3. PUT  <presigned URL>                 스토리지에 직접 올린다
 *   4. POST /api/v1/versions/:id/complete   다 올렸다고 알린다
 *
 * 1번이 성공하고 뒤가 실패하면 앱은 남긴다. 되돌리지 않는 이유는 ADR-0031 에 있다.
 */
(function () {
    "use strict";

    /*
     * dmg 는 버전을 미리 알 수 없어서 임시값으로 시작한다.
     *
     * `versions.short_version` 과 `build_number` 가 둘 다 not null 이라 비워둘 수
     * 없다. 워커가 번들에서 읽은 값으로 서버가 고친다. 그 사이 버전은 `업로드됨`
     * 이거나 `서명 중` 이라 아무도 설치할 수 없다.
     */
    var PROVISIONAL_VERSION = "0.0.0";

    var form = document.getElementById("app-new-form");
    var stepFile = document.getElementById("step-file");
    var stepInfo = document.getElementById("step-info");
    var dropzone = document.getElementById("dropzone");
    var input = document.getElementById("bundle-file");
    if (!form || !stepFile || !stepInfo || !dropzone || !input) return;

    var dropStatus = document.getElementById("dropzone-status");
    var infoLead = document.getElementById("step-info-lead");
    var dmgWarning = document.getElementById("dmg-warning");
    var firstVersion = document.getElementById("first-version");
    var signingChoice = document.getElementById("signing-choice");
    var errorBox = document.getElementById("app-new-error");
    var submit = document.getElementById("app-new-submit");
    var backButton = document.getElementById("back-to-file");
    var cancelInfo = document.getElementById("cancel-info");
    var skipFile = document.getElementById("skip-file");
    var optionalFields = document.getElementById("optional-fields");
    var progressRow = document.getElementById("app-new-progress");
    var bar = document.getElementById("app-new-bar");
    var progressLabel = document.getElementById("app-new-status");

    // 스크립트가 도니 1단계부터 시작한다.
    stepFile.hidden = false;
    stepInfo.hidden = true;
    backButton.hidden = false;
    cancelInfo.hidden = true;

    // MARK: - 1단계

    // 브라우저 기본 동작은 놓은 파일을 그 창에서 열어버린다. 그러면 우리 화면이
    // 사라지고 사용자는 앱 파일을 브라우저가 다운로드하는 것을 본다.
    ["dragenter", "dragover", "dragleave", "drop"].forEach(function (name) {
        dropzone.addEventListener(name, function (event) {
            event.preventDefault();
            event.stopPropagation();
        });
    });
    ["dragenter", "dragover"].forEach(function (name) {
        dropzone.addEventListener(name, function () {
            dropzone.classList.add("dropzone-armed");
        });
    });
    ["dragleave", "drop"].forEach(function (name) {
        dropzone.addEventListener(name, function () {
            dropzone.classList.remove("dropzone-armed");
        });
    });

    dropzone.addEventListener("drop", function (event) {
        var files = event.dataTransfer && event.dataTransfer.files;
        if (!files || !files.length) return;
        // 파일 입력에 넣어둔다. 업로드할 때 그 자리에서 다시 꺼내 쓴다.
        input.files = files;
        accept(files[0]);
    });

    input.addEventListener("change", function () {
        if (input.files[0]) accept(input.files[0]);
    });

    skipFile.addEventListener("click", function () {
        // 파일 없이 앱만 등록한다. 스크립트가 없을 때와 같은 경로다.
        input.value = "";
        go(null);
    });

    backButton.addEventListener("click", function () {
        input.value = "";
        dropzone.classList.remove("dropzone-filled");
        say(null);
        showError(null);
        stepInfo.hidden = true;
        stepFile.hidden = false;
    });

    function accept(file) {
        dropzone.classList.add("dropzone-filled");
        showError(null);
        say(file.name + " 를 읽는 중…");

        readBundle(file).then(function (info) {
            go(info);
        }).catch(function (error) {
            // 읽지 못하는 것은 dmg 이거나 우리가 다루지 못하는 zip 이다. 둘 다
            // 올리는 데는 문제가 없다. 값만 사람이 채우면 된다.
            go(null, error.message);
        });
    }

    async function readBundle(file) {
        return await window.AlleyBundleInfo.read(file);
    }

    // MARK: - 2단계

    /*
     * `info` 가 있으면 zip 을 읽어낸 것이다. 없으면 dmg 이거나 파일을 안 골랐다.
     */
    function go(info, whyNotRead) {
        var hasFile = !!input.files[0];

        if (info) {
            fill(info);
            infoLead.textContent = "번들에서 읽은 값입니다. 확인하고 모자란 것을 채우세요.";
            dmgWarning.hidden = true;
            firstVersion.hidden = false;
        } else if (hasFile) {
            infoLead.textContent = "이 파일에서는 값을 읽지 못했습니다. 번들 ID 를 적어주세요.";
            dmgWarning.hidden = false;
            // 버전 칸을 감춘다. 사람이 짐작해 적을 값이 아니다. 워커가 채운다.
            firstVersion.hidden = true;
            if (whyNotRead) say(whyNotRead);
            // 이름은 파일 이름에서 짐작해 둔다. 나중에 고칠 수 있는 값이다.
            var guess = input.files[0].name.replace(/\.(zip|dmg)$/i, "");
            if (!form.elements.name.value.trim()) form.elements.name.value = guess;
        } else {
            infoLead.textContent =
                "앱만 먼저 등록합니다. 파일은 등록 뒤 버전 화면에서 올리면 됩니다.";
            dmgWarning.hidden = true;
            firstVersion.hidden = true;
        }

        signingChoice.hidden = !hasFile;

        // 접어둔 칸을 언제 펼치는가.
        //
        // 이름이 비어 있으면 **반드시 펼친다.** `required` 인 칸이 닫힌 `<details>`
        // 안에 있으면 브라우저가 "invalid form control is not focusable" 로 제출을
        // 막고, 화면에는 아무 표시도 나지 않는다. 사람은 등록 버튼이 죽은 줄 안다.
        //
        // zip 은 읽은 값을 보여주는 것이 이 단계의 목적이라 펼친다. dmg 는 이름을
        // 파일 이름에서 채워뒀고 적어야 할 것은 번들 ID 하나뿐이라 접어둔다.
        optionalFields.open = !form.elements.name.value.trim() || !!info;

        stepFile.hidden = true;
        stepInfo.hidden = false;
        (form.elements.bundleID.value.trim()
            ? form.elements.name
            : form.elements.bundleID).focus();
    }

    function fill(info) {
        [
            ["bundleID", info.bundleID],
            ["name", info.name],
            ["shortVersion", info.shortVersion],
            ["buildNumber", info.buildNumber],
            ["minimumOSVersion", info.minimumOSVersion]
        ].forEach(function (row) {
            var field = form.elements[row[0]];
            var value = row[1];
            if (!field || !value) return;
            // 빌드 번호는 서버가 정수로 받는다. 번들이 "0.7.10" 처럼 적어두는 일이
            // 흔해서, 숫자로 읽히지 않으면 서버가 제안한 값을 그대로 둔다.
            if (row[0] === "buildNumber" && !/^\d+$/.test(value)) return;
            if (isOursToFill(field)) {
                field.value = value;
                field.dataset.filledFromBundle = "1";
            }
        });
        say("번들에서 읽었습니다: " + (info.bundleID || "번들 ID 없음"));
    }

    /*
     * 이 칸을 우리가 채워도 되는가. upload.js 와 같은 규칙이다.
     *
     * 비어 있거나, 앞서 우리가 채웠거나, 서버가 제안한 값 그대로면 채운다.
     */
    function isOursToFill(field) {
        if (field.value.trim() === "") return true;
        if (field.dataset.filledFromBundle === "1") return true;
        var suggested = field.dataset.suggested;
        return suggested !== undefined && field.value.trim() === suggested.trim();
    }

    // MARK: - 등록

    form.addEventListener("submit", function (event) {
        // 파일이 없으면 평소대로 폼을 넘긴다. 서버가 등록하고 리다이렉트한다.
        if (!input.files[0]) return;

        event.preventDefault();
        run().catch(function (error) {
            fail(error.message || "등록에 실패했습니다.");
        });
    });

    async function run() {
        var file = input.files[0];

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
            // 앱은 이미 만들어졌다. 숨기면 다시 등록하려다 번들 ID 중복에 막힌다.
            throw new Error(
                error.message + "\n\n" +
                "앱은 등록됐습니다. 파일만 올라가지 않았으니 앱 화면에서 새 버전으로 다시 올리세요: " +
                "/apps/" + app.id
            );
        }

        window.location.href = "/apps/" + app.id;
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
        // 버전 칸이 감춰져 있으면 dmg 다. 임시값으로 만들고 워커가 고친다.
        var provisional = firstVersion.hidden;
        return await postJSON(form.dataset.appsUrl + "/" + appID + "/versions", {
            shortVersion: provisional
                ? PROVISIONAL_VERSION
                : form.elements.shortVersion.value.trim(),
            buildNumber: provisional ? 1 : Number(form.elements.buildNumber.value),
            uploadKind: form.querySelector("input[name=uploadKind]:checked").value,
            releaseNotes: null,
            minimumOSVersion: provisional
                ? null
                : emptyToNull(form.elements.minimumOSVersion.value),
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

    // MARK: - 화면

    function setProgress(percent, text) {
        bar.value = percent;
        progressLabel.textContent = text;
    }

    function busy(isBusy) {
        submit.disabled = isBusy;
        backButton.disabled = isBusy;
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
        if (!dropStatus) return;
        dropStatus.hidden = message === null;
        dropStatus.textContent = message || "";
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
