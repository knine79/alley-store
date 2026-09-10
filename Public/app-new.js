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
    var bundleIDField = document.getElementById("bundle-id-field");
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
            infoLead.textContent =
                "이 파일은 열어볼 수 없어서 올린 뒤에 앱 정보를 읽습니다.";
            dmgWarning.hidden = false;
            // 버전도 번들 ID 도 묻지 않는다. 사람이 짐작해 적을 값이 아니고, 적게
            // 하면 실제와 어긋난 채로 올라간다. 워커가 번들에서 읽어 확정한다.
            firstVersion.hidden = true;
            if (whyNotRead) say(whyNotRead);
            // 이름은 파일 이름에서 짐작해 둔다. 확인 화면에서 고친다.
            var guess = input.files[0].name.replace(/\.(zip|dmg)$/i, "");
            if (!form.elements.name.value.trim()) form.elements.name.value = guess;
        } else {
            infoLead.textContent =
                "앱만 먼저 등록합니다. 파일은 등록 뒤 버전 화면에서 올리면 됩니다.";
            dmgWarning.hidden = true;
            firstVersion.hidden = true;
        }

        signingChoice.hidden = !hasFile;

        // 이름·소개·설명·분류를 언제 보여주는가.
        //
        // dmg 는 **통째로 감춘다.** 그때 적어야 하는 것은 번들 ID 하나뿐인데 아래
        // 네 칸이 비어 있으면 무엇을 더 해야 하는지 찾게 된다. 이름은 파일 이름에서
        // 채워두고, 올린 뒤 확인 화면에서 워커가 읽은 값과 함께 고친다.
        //
        // zip 은 읽은 값을 보여주는 것이 이 단계의 목적이라 드러낸다. 파일이 없으면
        // 이름을 적을 곳이 여기뿐이라 역시 드러낸다.
        //
        // 감출 때 `required` 도 떼어야 한다. 안 떼면 브라우저가
        // "invalid form control is not focusable" 로 제출을 막는데 화면에는 아무
        // 표시도 나지 않는다. 사람은 등록 버튼이 죽은 줄 안다.
        var hideOptional = hasFile && !info;
        optionalFields.hidden = hideOptional;
        form.elements.name.required = !hideOptional;

        // dmg 면 번들 ID 도 묻지 않는다. 서버가 임시값으로 만들어두고 워커가 번들에서
        // 읽은 값으로 확정한다 (ADR-0034). 감출 때 `required` 를 떼야 브라우저가
        // 조용히 제출을 막지 않는다.
        bundleIDField.hidden = hideOptional;
        form.elements.bundleID.required = !hideOptional;

        // 버튼 이름을 하는 일에 맞춘다. 파일이 있으면 올리는 것이 이 단계의 일이다.
        submit.textContent = hasFile ? "업로드" : "등록";

        stepFile.hidden = true;
        stepInfo.hidden = false;
        if (!bundleIDField.hidden && !form.elements.bundleID.value.trim()) {
            form.elements.bundleID.focus();
        } else if (!optionalFields.hidden) {
            form.elements.name.focus();
        }
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

        // 번들 ID 를 우리가 정하지 못한 채로 올린다. 그 사실과 대가를 올리기 직전에
        // 한 번 확인받는다. 몇백 MB 를 보낸 뒤에 "규칙에 안 맞아 실패했다" 를 처음
        // 듣게 하지 않으려는 것이다.
        if (bundleIDField.hidden && !confirmPolicy()) return;

        run().catch(function (error) {
            fail(error.message || "등록에 실패했습니다.");
        });
    });

    /*
     * 올리기 직전 확인.
     *
     * `confirm` 은 투박하지만 이 자리에는 맞다. 되돌리기 어려운 일을 하기 전에
     * 멈춰 세우는 것이 목적이고, 브라우저가 그리는 창은 사람이 이미 아는 모양이다.
     * 직접 만든 대화상자는 초점 가두기와 Esc 처리를 다시 만들어야 하는데, 이 콘솔에
     * 그런 장치가 아직 없다.
     */
    function confirmPolicy() {
        var rule = form.dataset.bundleIdPrefix;
        var lines = [
            "이 파일은 열어볼 수 없어서 앱 정보를 모른 채로 올립니다.",
            "",
            "올리고 나면 서명 워커가 번들을 열어 번들 ID 를 읽습니다."
        ];
        if (rule) {
            lines.push(
                "그 값이 " + rule + ". 로 시작하지 않으면 업로드가 끝난 뒤 실패합니다."
            );
        }
        lines.push("", "계속할까요?");
        return window.confirm(lines.join("\n"));
    }

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

        // 앱 화면이 아니라 확인 화면으로 간다. dmg 는 버전을 아직 모르고, 워커가
        // 번들을 열어 보고할 때까지 기다렸다가 무엇을 올린 것인지 보여준다.
        window.location.href =
            "/apps/" + app.id + "/versions/" + ticket.version.id + "/confirm";
    }

    async function createApp() {
        return await postJSON(form.dataset.appsUrl, {
            // 감춰져 있으면 보내지 않는다. 서버가 임시값을 만들고 워커가 확정한다.
            bundleID: bundleIDField.hidden
                ? null
                : form.elements.bundleID.value.trim(),
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
        submit.textContent = isBusy
            ? (input.files[0] ? "올리는 중…" : "등록하는 중…")
            : (input.files[0] ? "업로드" : "등록");
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
