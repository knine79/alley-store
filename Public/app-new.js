/*
 * 새 앱 등록 화면의 "번들에서 값 읽어오기".
 *
 * 이 화면은 스크립트 없이도 동작한다. 폼은 그대로 `POST` 되고, 사람이 번들 ID 와
 * 이름을 직접 적으면 된다. 이 스크립트는 그 타이핑을 덜어주기만 한다.
 * 그래서 파일 칸은 HTML 에서 `hidden` 이고 여기서 벗긴다. 스크립트가 없을 때
 * 아무 일도 하지 않는 칸을 보여주면 고장으로 읽힌다 (ADR-0030).
 *
 * 고른 파일은 서버로 가지 않는다. 브라우저 안에서 Info.plist 만 읽고 버린다.
 * 업로드는 등록을 마친 뒤 버전 화면에서 따로 한다.
 */
(function () {
    "use strict";

    var form = document.getElementById("app-new-form");
    var picker = document.getElementById("bundle-picker");
    var input = document.getElementById("bundle-file");
    var status = document.getElementById("bundle-read-status");
    if (!form || !picker || !input) return;

    picker.hidden = false;

    input.addEventListener("change", function () {
        fill().catch(function (error) {
            say("번들에서 값을 읽지 못했습니다. 아래 칸을 직접 채우세요. (" + error.message + ")");
        });
    });

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
            ["name", info.name, "이름"]
        ].forEach(function (row) {
            var field = form.elements[row[0]];
            var value = row[1];
            if (!field || !value) return;

            // 사람이 적은 값은 덮지 않는다. 우리가 채운 값은 다시 채운다. 파일을
            // 바꿔 골랐을 때 앞 번들의 값이 남아 있으면 그게 더 헷갈린다.
            if (field.value.trim() === "" || field.dataset.filledFromBundle === "1") {
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
        if (!filled.length && !kept.length) {
            lines.push("번들에 번들 ID 와 이름이 없었습니다.");
        }
        say(lines.join(" / "));
    }

    function say(message) {
        if (!status) return;
        status.hidden = message === null;
        status.textContent = message || "";
    }
})();
