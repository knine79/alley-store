/*
 * 새 앱 등록. 두 단계다 (ADR-0033).
 *
 *   1단계  파일을 끌어다 놓는다. 다른 입력은 없다
 *   2단계  값을 확인하고 모자란 것을 채운다
 *
 * zip 이면 1단계에서 번들을 열어 칸을 채운 뒤 2단계로 넘긴다. dmg 는 브라우저가
 * 열 수 없어서 아무것도 묻지 않는다. 번들 ID·버전·최소 macOS 를 올린 뒤 서명 워커가
 * 번들에서 읽어 서버가 채운다 (ADR-0034).
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
    var dmgDialog = document.getElementById("dmg-dialog");
    var firstVersion = document.getElementById("first-version");
    var errorBox = document.getElementById("app-new-error");
    var submit = document.getElementById("app-new-submit");
    var backButton = document.getElementById("back-to-file");
    var cancelInfo = document.getElementById("cancel-info");
    var skipFile = document.getElementById("skip-file");
    var optionalFields = document.getElementById("optional-fields");
    var bundleIDField = document.getElementById("bundle-id-field");
    var appInfoGroup = document.getElementById("app-info-group");
    var progressRow = document.getElementById("app-new-progress");
    var bar = document.getElementById("app-new-bar");
    var progressLabel = document.getElementById("app-new-status");

    /** 올리는 중인가. 1단계에 머문 채로 올라가므로 그 화면의 조작을 잠가야 한다. */
    var locked = false;

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
        if (locked) return;
        var files = event.dataTransfer && event.dataTransfer.files;
        if (!files || !files.length) return;
        // 파일 입력에 넣어둔다. 업로드할 때 그 자리에서 다시 꺼내 쓴다.
        input.files = files;
        accept(files[0]);
    });

    input.addEventListener("change", function () {
        if (locked) return;
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
            switch (error.kind) {
            case "diskImage":
                // 열어볼 수 없는 것이 정상이다. 아무것도 묻지 않고 확인만 받는다.
                go(null, null, true);
                break;
            case "notAnArchive":
            case "notAnAppBundle":
                // **올려봐야 서명할 것이 없다.** 여기서 막지 않으면 몇백 MB 를 보낸
                // 뒤에 워커가 "번들이 없다" 로 실패시킨다. 브라우저가 이미 알고 있는
                // 사실을 굳이 스토리지까지 다녀와서 알려줄 이유가 없다.
                refuse(error.message);
                break;
            default:
                // zip 이긴 한데 우리가 못 읽었다(zip64 등). 올리는 데는 문제 없으니
                // 사람이 값을 채우게 한다.
                go(null, error.message, false);
            }
        });
    }

    /** 받을 수 없는 파일. 고른 것을 지우고 왜인지 말한다. */
    function refuse(message) {
        input.value = "";
        dropzone.classList.remove("dropzone-filled");
        say(null);
        showError(message);
    }

    async function readBundle(file) {
        return await window.AlleyBundleInfo.read(file);
    }

    // MARK: - 2단계

    /*
     * `info` 가 있으면 zip 을 읽어낸 것이다. 없으면 dmg 이거나 파일을 안 골랐다.
     */
    function go(info, whyNotRead, isDiskImage) {
        var hasFile = !!input.files[0];

        if (info) {
            fill(info);
            infoLead.textContent = "번들에서 읽은 값입니다. 확인하고 모자란 것을 채우세요.";
            firstVersion.hidden = false;
        } else if (hasFile && isDiskImage) {
            infoLead.textContent =
                "이 파일은 열어볼 수 없어서 올린 뒤에 앱 정보를 읽습니다.";
            // 버전도 번들 ID 도 묻지 않는다. 사람이 짐작해 적을 값이 아니고, 적게
            // 하면 실제와 어긋난 채로 올라간다. 워커가 번들에서 읽어 확정한다.
            firstVersion.hidden = true;
            if (whyNotRead) say(whyNotRead);
            // 이름은 파일 이름에서 짐작해 둔다. 확인 화면에서 고친다.
            var guess = input.files[0].name.replace(/\.(zip|dmg)$/i, "");
            if (!form.elements.name.value.trim()) form.elements.name.value = guess;
        } else if (hasFile) {
            // zip 인데 값을 못 읽었다. 올릴 수는 있으니 사람이 채우게 한다.
            infoLead.textContent = "번들에서 값을 읽지 못했습니다. 직접 채우세요.";
            firstVersion.hidden = false;
            if (whyNotRead) say(whyNotRead);
        } else {
            infoLead.textContent =
                "앱만 먼저 등록합니다. 파일은 등록 뒤 버전 화면에서 올리면 됩니다.";
            firstVersion.hidden = true;
        }

        // 이름·소개·설명·분류를 언제 보여주는가.
        //
        // dmg 는 **통째로 감춘다.** 그때 적어야 하는 것은 번들 ID 하나뿐인데 아래
        // 네 칸이 비어 있으면 무엇을 더 해야 하는지 찾게 된다. 이름은 파일 이름에서
        // 채워두고, 올린 뒤 확인 화면에서 번들에서 읽은 값과 함께 고친다.
        //
        // zip 은 읽은 값을 보여주는 것이 이 단계의 목적이라 드러낸다. 파일이 없으면
        // 이름을 적을 곳이 여기뿐이라 역시 드러낸다.
        //
        // 감출 때 `required` 도 떼어야 한다. 안 떼면 브라우저가
        // "invalid form control is not focusable" 로 제출을 막는데 화면에는 아무
        // 표시도 나지 않는다. 사람은 등록 버튼이 죽은 줄 안다.
        // **읽지 못한 것과 dmg 는 다르다.** 예전에는 둘을 같이 다뤄서, 앱이 아닌
        // zip 을 올려도 dmg 처럼 아무것도 묻지 않고 넘어갔다.
        var hideOptional = hasFile && isDiskImage === true;
        optionalFields.hidden = hideOptional;
        form.elements.name.required = !hideOptional;

        // dmg 면 번들 ID 도 묻지 않는다. 서버가 임시값으로 만들어두고 워커가 번들에서
        // 읽은 값으로 확정한다 (ADR-0034). 감출 때 `required` 를 떼야 브라우저가
        // 조용히 제출을 막지 않는다.
        bundleIDField.hidden = hideOptional;
        form.elements.bundleID.required = !hideOptional;

        // 둘 다 감추면 이 묶음에 제목만 남는다. 빈 상자에 "앱 정보" 라고 써 있으면
        // 뭘 채워야 하는지 찾게 된다.
        appInfoGroup.hidden = bundleIDField.hidden && optionalFields.hidden;

        // 버튼 이름을 하는 일에 맞춘다. 파일이 있으면 올리는 것이 이 단계의 일이다.
        submit.textContent = hasFile ? "업로드" : "등록";

        // dmg 는 2단계에 적을 것이 하나도 없다. 화면 하나를 더 거치게 하는 대신
        // 곧장 확인 팝업을 띄운다 (ADR-0037). 1단계에 머무르므로 취소하면 다른
        // 파일을 바로 고를 수 있다.
        if (hideOptional) {
            askThenUpload();
            return;
        }

        stepFile.hidden = true;
        stepInfo.hidden = false;
        if (!bundleIDField.hidden && !form.elements.bundleID.value.trim()) {
            form.elements.bundleID.focus();
        } else if (!optionalFields.hidden) {
            form.elements.name.focus();
        }
    }

    /**
     * 확인 팝업을 띄우고, 승낙하면 바로 올린다.
     *
     * 취소하면 고른 것을 지운다. 1단계에는 "다음" 이 없어서, 남겨두면 같은 파일을
     * 다시 고르기 전에는 아무 데도 갈 수 없다.
     */
    function askThenUpload() {
        confirmPolicy().then(function (agreed) {
            if (!agreed) {
                input.value = "";
                dropzone.classList.remove("dropzone-filled");
                say(null);
                return;
            }
            return run();
        }).catch(function (error) {
            fail(error.message || "등록에 실패했습니다.");
        });
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
        var asked = bundleIDField.hidden ? confirmPolicy() : Promise.resolve(true);
        asked.then(function (agreed) {
            if (!agreed) return;
            return run();
        }).catch(function (error) {
            fail(error.message || "등록에 실패했습니다.");
        });
    });

    /*
     * 올리기 직전 확인 (ADR-0037).
     *
     * 네이티브 `<dialog>` 라서 Esc·초점 가두기·배경 가림이 딸려 온다. 문구는
     * 템플릿에 있다. 접두어 정책이 서버 설정이라 여기서 조립하면 두 군데가 어긋난다.
     *
     * **`close` 이벤트를 믿지 않는다.** Chrome 152 헤드리스에서는 `dialog.close()`
     * 로 닫아도 `close` 가 오지 않았다. 그 이벤트만 기다리면 업로드를 눌러도 아무
     * 일이 일어나지 않는다. 실제로 그렇게 만들었다가 브라우저로 몰아보고 잡았다.
     * 대신 확실히 오는 둘에 건다. 버튼은 폼 `submit`, Esc 는 `cancel` 이다.
     * `close` 도 함께 달아두지만 셋 중 먼저 오는 것 하나만 쓴다.
     *
     * `<dialog>` 를 모르는 브라우저에서는 확인을 건너뛰지 않고 `confirm` 으로
     * 떨어진다. 확인 없이 몇백 MB 를 보내게 두는 것보다 투박한 창이 낫다.
     */
    function confirmPolicy() {
        var dialogForm = dmgDialog && dmgDialog.querySelector("form");
        if (!dmgDialog || !dialogForm || typeof dmgDialog.showModal !== "function") {
            return Promise.resolve(window.confirm(dialogText() + "\n\n계속할까요?"));
        }

        return new Promise(function (resolve) {
            function settle(agreed) {
                dialogForm.removeEventListener("submit", onSubmit);
                dmgDialog.removeEventListener("cancel", onCancel);
                dmgDialog.removeEventListener("close", onClose);
                if (dmgDialog.open) dmgDialog.close();
                resolve(agreed);
            }
            // 어느 버튼인지 모르면 안 올린다. 되돌릴 수 없는 쪽으로 기울지 않는다.
            function onSubmit(event) {
                settle(!!event.submitter && event.submitter.value === "upload");
            }
            function onCancel() { settle(false); }
            function onClose() { settle(dmgDialog.returnValue === "upload"); }

            dmgDialog.returnValue = "";
            dialogForm.addEventListener("submit", onSubmit);
            dmgDialog.addEventListener("cancel", onCancel);
            dmgDialog.addEventListener("close", onClose);
            dmgDialog.showModal();
        });
    }

    /** 팝업 본문을 한 줄로. `confirm` 으로 떨어졌을 때 같은 말을 하려고 읽는다. */
    function dialogText() {
        var body = dmgDialog && dmgDialog.querySelector(".modal-body");
        if (!body) return "올린 뒤에야 앱 정보를 읽을 수 있습니다.";
        return Array.prototype.map.call(body.querySelectorAll("p"), function (node) {
            return node.textContent.replace(/\s+/g, " ").trim();
        }).join("\n");
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
            releaseNotes: null,
            minimumOSVersion: provisional
                ? null
                : emptyToNull(form.elements.minimumOSVersion.value)
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
        locked = isBusy;
        submit.disabled = isBusy;
        backButton.disabled = isBusy;
        // dmg 는 1단계에 머문 채로 올라간다. 그 화면의 조작도 함께 잠근다.
        input.disabled = isBusy;
        skipFile.disabled = isBusy;
        dropzone.classList.toggle("dropzone-locked", isBusy);
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
