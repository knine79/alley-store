/*
 * 올린 뒤 확인 화면.
 *
 * dmg 로 올리면 버전과 최소 macOS 를 브라우저가 미리 읽을 수 없다. 서명 워커가
 * 번들을 열어 보고해야 알 수 있는데, 그게 몇 초에서 몇 분 걸린다 (ADR-0033).
 * 그동안 사람이 새로고침을 눌러야 한다면 이 화면이 있으나 마나다. 그래서 값이 올
 * 때까지 버전을 폴링한다.
 *
 * **스크립트가 없어도 화면은 쓸 수 있다.** 값 자리에 `—` 가 남을 뿐, 이름과 설명을
 * 적어 저장하는 폼은 그대로 동작한다.
 */
(function () {
    "use strict";

    var section = document.getElementById("analysis");
    if (!section) return;

    var status = document.getElementById("analysis-status");
    var facts = document.getElementById("analysis-facts");
    var errorBox = document.getElementById("analysis-error");
    var path = section.dataset.versionPath;

    /*
     * 폴링 간격을 늘려간다.
     *
     * 워커가 잡을 집는 데 보통 몇 초, 공증까지는 몇 분이 걸린다. 처음부터 느리면
     * 빨리 끝난 경우에 답답하고, 계속 빠르면 오래 걸릴 때 요청만 쌓인다.
     */
    var DELAYS = [1000, 1000, 2000, 2000, 3000, 5000];
    var MAX_DELAY = 10000;
    /** 10분. 이보다 오래 걸리면 워커가 없거나 막힌 것이다. */
    var GIVE_UP_AFTER = 10 * 60 * 1000;

    var startedAt = Date.now();
    var attempt = 0;

    poll();

    async function poll() {
        var version;
        try {
            var response = await fetch(path, { credentials: "same-origin" });
            if (!response.ok) throw new Error("버전을 조회하지 못했습니다 (" + response.status + ").");
            version = await response.json();
        } catch (error) {
            // 일시적인 네트워크 실패로 화면을 포기하지 않는다. 다음 차례에 다시 본다.
            return again();
        }

        show(version);

        if (isSettled(version.state)) return;
        if (Date.now() - startedAt > GIVE_UP_AFTER) {
            status.textContent =
                "서명 워커가 아직 가져가지 않았습니다. 워커가 꺼져 있을 수 있습니다. " +
                "이 화면을 닫아도 되고, 앱 화면에서 상태를 계속 볼 수 있습니다.";
            return;
        }
        again();
    }

    function again() {
        var delay = attempt < DELAYS.length ? DELAYS[attempt] : MAX_DELAY;
        attempt += 1;
        setTimeout(poll, delay);
    }

    /** 더 기다려도 값이 바뀌지 않는 상태. */
    function isSettled(state) {
        return state === "ready" || state === "released" || state === "failed";
    }

    function show(version) {
        facts.hidden = false;
        text("fact-version", version.shortVersion);
        text("fact-build", version.buildNumber);
        text("fact-minimum", version.minimumOSVersion);
        text("fact-size", version.fileSize ? readableSize(version.fileSize) : null);

        if (version.state === "failed") {
            status.textContent = "서명에 실패했습니다.";
            errorBox.hidden = false;
            errorBox.textContent =
                (version.failureReason || "실패 이유가 기록되지 않았습니다.") +
                "\n앱 화면에서 다시 시도할 수 있습니다.";
            return;
        }
        if (isSettled(version.state)) {
            status.textContent = "번들에서 읽었습니다.";
            return;
        }
        status.textContent = phase(version.state);
    }

    function phase(state) {
        switch (state) {
            case "uploaded": return "서명 워커가 가져가기를 기다리는 중…";
            case "signing": return "서명하는 중…";
            case "notarizing": return "Apple 공증을 기다리는 중… 몇 분 걸립니다.";
            default: return "처리 중…";
        }
    }

    function text(id, value) {
        var node = document.getElementById(id);
        if (!node) return;
        // 아직 모르는 값은 `—` 그대로 둔다. 빈 칸으로 두면 자리가 무너진다.
        node.textContent = (value === null || value === undefined || value === "")
            ? "—"
            : String(value);
    }

    function readableSize(bytes) {
        if (bytes < 1024) return bytes + " B";
        var units = ["KB", "MB", "GB"];
        var value = bytes / 1024;
        for (var i = 0; i < units.length; i++) {
            if (value < 1024 || i === units.length - 1) {
                return (value < 10 ? value.toFixed(1) : Math.round(value)) + " " + units[i];
            }
            value /= 1024;
        }
        return bytes + " B";
    }
})();
