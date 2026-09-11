/*
 * 새 버전 올리기. 새 앱 등록과 같은 두 단계다 (ADR-0033, ADR-0040).
 *
 *   1단계  파일을 끌어다 놓는다. 다른 입력은 없다
 *   2단계  읽은 값을 확인하고 바뀐 것을 적는다. 둘 다 선택이다
 *
 * **올리는 사람이 macOS 개발자라고 가정하지 않는다.** 버전·빌드 번호·필요한 macOS
 * 는 전부 파일 안에 있다. 읽을 수 있으면 읽어서 보여주기만 하고, 못 읽었을 때만 묻는다.
 *
 * 올리는 것은 세 요청이다.
 *
 *   1. POST /api/v1/apps/:id/versions       버전을 만들고 올릴 자리를 받는다
 *   2. PUT  <presigned URL>                 스토리지에 직접 올린다 (ADR-0009)
 *   3. POST /api/v1/versions/:id/complete   다 올렸다고 알린다
 *
 * 빌드 스텝 없이 브라우저가 그대로 읽습니다. 번들러도 프레임워크도 쓰지 않습니다.
 */
(function () {
    "use strict";

    /* dmg 는 버전을 미리 알 수 없어서 임시값으로 시작한다. 워커가 읽은 값으로
       서버가 고친다 (ADR-0034). */
    var PROVISIONAL_VERSION = "0.0.0";

    var form = document.getElementById("upload-form");
    var stepFile = document.getElementById("step-file");
    var stepInfo = document.getElementById("step-info");
    var dropzone = document.getElementById("dropzone");
    var input = document.getElementById("bundle-file");
    if (!form || !stepFile || !stepInfo || !dropzone || !input) return;

    var dropStatus = document.getElementById("dropzone-status");
    var infoLead = document.getElementById("step-info-lead");
    var facts = document.getElementById("read-facts");
    var manualFields = document.getElementById("manual-fields");
    var errorBox = document.getElementById("upload-error");
    var submit = document.getElementById("upload-submit");
    var backButton = document.getElementById("back-to-file");
    var progressRow = document.getElementById("upload-progress");
    var bar = document.getElementById("upload-bar");
    var progressLabel = document.getElementById("upload-status");

    /** 올리는 중인가. 그동안 파일을 바꾸지 못하게 한다. */
    var locked = false;

    backButton.hidden = false;
    stepFile.hidden = false;
    stepInfo.hidden = true;

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
        input.files = files;
        accept(files[0]);
    });

    input.addEventListener("change", function () {
        if (locked) return;
        if (input.files[0]) accept(input.files[0]);
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

        window.AlleyBundleInfo.read(file).then(function (info) {
            // **이 앱이 맞는지 먼저 본다.** 다른 앱 파일을 올리면 몇백 MB 를 보낸 뒤
            // 서명 직전에 막힌다 (ADR-0029). 브라우저가 이미 아는 것을 스토리지까지
            // 다녀와서 알려줄 이유가 없다.
            var expected = form.dataset.appBundleId;
            if (expected && info.bundleID && info.bundleID !== expected) {
                refuse("이 파일은 다른 앱입니다. " + info.bundleID + " 의 파일이네요.");
                return;
            }
            go(info);
        }).catch(function (error) {
            switch (error.kind) {
            case "diskImage":
                // 열어볼 수 없는 것이 정상이다. 올린 뒤에 읽는다.
                go(null, null, true);
                break;
            case "notAnArchive":
            case "notAnAppBundle":
                refuse(error.message);
                break;
            default:
                // zip 이긴 한데 우리가 못 읽었다(zip64 등). 그때만 손으로 받는다.
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

    // MARK: - 2단계

    /**
     * `info` 가 있으면 zip 을 읽어낸 것이다. `isDiskImage` 면 dmg 라 읽을 수 없다.
     * 둘 다 아니면 zip 인데 우리가 못 읽은 것이고, 그때만 사람에게 묻는다.
     */
    function go(info, whyNotRead, isDiskImage) {
        if (info) {
            fill(info);
            infoLead.textContent = "파일에서 읽은 값입니다. 맞으면 그대로 올리세요.";
            facts.hidden = false;
            manualFields.hidden = true;
        } else if (isDiskImage) {
            infoLead.textContent =
                "이 파일은 다 올린 뒤에야 열어볼 수 있습니다. 버전은 그때 읽어서 채웁니다.";
            facts.hidden = true;
            manualFields.hidden = true;
        } else {
            infoLead.textContent = "파일에서 버전을 읽지 못했습니다. 직접 적어주세요.";
            facts.hidden = true;
            manualFields.hidden = false;
            if (whyNotRead) say(whyNotRead);
        }

        // 감출 때 `required` 도 떼어야 한다. 안 떼면 브라우저가 "invalid form control
        // is not focusable" 로 제출을 막는데 화면에는 아무 표시도 나지 않는다.
        form.elements.shortVersion.required = !manualFields.hidden;
        form.elements.buildNumber.required = !manualFields.hidden;

        stepFile.hidden = true;
        stepInfo.hidden = false;
        if (!manualFields.hidden) form.elements.shortVersion.focus();
    }

    function fill(info) {
        form.elements.shortVersion.value = info.shortVersion || "";
        form.elements.minimumOSVersion.value = info.minimumOSVersion || "";
        // 빌드 번호는 서버가 정수로 받는다. 번들이 "0.7.10" 처럼 적어두는 일이 흔해서,
        // 숫자로 읽히지 않으면 서버가 제안한 다음 번호를 그대로 쓴다.
        if (/^\d+$/.test(info.buildNumber || "")) {
            form.elements.buildNumber.value = info.buildNumber;
        }

        text("fact-version", info.shortVersion);
        text("fact-build", form.elements.buildNumber.value);
        text("fact-minimum", info.minimumOSVersion ? info.minimumOSVersion + " 이상" : null);
    }

    function text(id, value) {
        var node = document.getElementById(id);
        if (node) node.textContent = value == null || value === "" ? "—" : String(value);
    }

    function say(message) {
        if (!dropStatus) return;
        dropStatus.hidden = message === null;
        dropStatus.textContent = message || "";
    }

    // MARK: - 올리기

    form.addEventListener("submit", function (event) {
        event.preventDefault();
        run().catch(function (error) {
            fail(error.message || "업로드에 실패했습니다.");
        });
    });

    async function run() {
        var file = input.files[0];
        if (!file) {
            fail("올릴 파일을 고르세요.");
            return;
        }

        busy(true);
        showError(null);
        progressRow.hidden = false;
        setProgress(0, "버전을 만드는 중…");

        var ticket = await createVersion();
        setProgress(0, "올리는 중…");
        await putFile(ticket.uploadURL, file);

        setProgress(100, "마무리하는 중…");
        await completeUpload(ticket.version.id);

        // 상세 화면이 새 버전을 상태와 함께 보여준다. 여기서 결과를 다시 그릴 이유가 없다.
        window.location.href = form.dataset.appUrl;
    }

    async function createVersion() {
        // dmg 는 버전을 아직 모른다. 임시값으로 만들고 올린 뒤 서버가 고친다.
        var unknown = facts.hidden && manualFields.hidden;
        var body = {
            shortVersion: unknown
                ? PROVISIONAL_VERSION
                : form.elements.shortVersion.value.trim(),
            buildNumber: Number(form.elements.buildNumber.value),
            releaseNotes: emptyToNull(form.elements.releaseNotes.value),
            minimumOSVersion: unknown
                ? null
                : emptyToNull(form.elements.minimumOSVersion.value)
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

    function setProgress(percent, label) {
        bar.value = percent;
        progressLabel.textContent = label;
    }

    function busy(isBusy) {
        locked = isBusy;
        submit.disabled = isBusy;
        backButton.disabled = isBusy;
        input.disabled = isBusy;
        dropzone.classList.toggle("dropzone-locked", isBusy);
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
