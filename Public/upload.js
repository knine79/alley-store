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
            uploadKind: form.querySelector("input[name=uploadKind]:checked").value,
            releaseNotes: emptyToNull(form.elements.releaseNotes.value),
            minimumOSVersion: emptyToNull(form.elements.minimumOSVersion.value)
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
