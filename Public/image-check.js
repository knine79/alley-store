/*
 * 고른 이미지가 조건에 맞는지 **고르는 순간** 알려준다.
 *
 * 서버도 같은 검사를 한다. 그쪽이 진짜 방어선이고 여기는 없어도 된다. 그런데
 * 서버만 있으면 사람이 파일을 고르고 → 올리기를 누르고 → 왕복을 기다린 뒤에야
 * "정사각형이어야 합니다" 를 본다. 1024×768 을 골랐다는 사실은 고른 순간에 이미
 * 정해져 있었다.
 *
 * 스크립트가 없어도 올리는 데 지장이 없다. 그때는 서버가 같은 말을 조금 늦게
 * 할 뿐이다.
 *
 * 외부 라이브러리를 안 쓰는 것은 취향이 아니라 제약이다. CSP 가 `script-src 'self'`
 * 라 CDN 에서 아무것도 못 받는다.
 */
(function () {
    "use strict";

    /** PNG 파일 시그니처. 이 여덟 바이트로 시작하지 않으면 PNG 가 아니다. */
    var SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

    /*
     * 머리 24바이트에서 크기를 읽는다.
     *
     * PNG 는 시그니처 뒤 첫 청크가 반드시 `IHDR` 이고 그 안에 크기가 있다. 규격이
     * 그렇게 정해 두어서 앞부분만 읽으면 된다. 서버의 `PNGInspection` 과 같은 일을
     * 한다.
     */
    async function readSize(file) {
        var bytes = new Uint8Array(await file.slice(0, 24).arrayBuffer());
        if (bytes.length < 24) return null;

        for (var i = 0; i < SIGNATURE.length; i++) {
            if (bytes[i] !== SIGNATURE[i]) return null;
        }
        if (String.fromCharCode.apply(null, bytes.subarray(12, 16)) !== "IHDR") return null;

        var view = new DataView(bytes.buffer);
        return { width: view.getUint32(16, false), height: view.getUint32(20, false) };
    }

    /*
     * 규칙에 맞는지 본다. 맞으면 null, 아니면 사람에게 할 말.
     *
     * 문구는 서버와 같은 뜻이어야 한다. 같은 파일을 두고 여기서는 이렇게 말하고
     * 서버는 저렇게 말하면, 둘 중 어느 쪽이 진짜인지 묻게 된다.
     */
    function complain(size, rule, label) {
        if (!size) {
            return label + "은 PNG 여야 합니다. 확장자만 바꾼 파일일 수 있습니다.";
        }
        if (size.width !== size.height) {
            return (
                label + "은 정사각형이어야 합니다. 고른 파일: " +
                size.width + "×" + size.height + "."
            );
        }
        if (rule.exactly) {
            if (rule.exactly.indexOf(size.width) < 0) {
                var list = rule.exactly.slice().sort(function (a, b) { return b - a; })
                    .map(function (edge) { return edge + "×" + edge; }).join(" 또는 ");
                return (
                    label + "은 " + list + " 여야 합니다. 고른 파일: " +
                    size.width + "×" + size.width + "."
                );
            }
        } else if (size.width < rule.atLeast) {
            return (
                label + "은 " + rule.atLeast + "×" + rule.atLeast + " 이상이어야 합니다. " +
                "고른 파일: " + size.width + "×" + size.width + "."
            );
        }
        return null;
    }

    /** `data-image-rule` 을 읽는다. `atLeast:32` 또는 `exactly:512,1024`. */
    function parseRule(raw) {
        var parts = (raw || "").split(":");
        if (parts[0] === "exactly") {
            return {
                exactly: parts[1].split(",").map(function (value) {
                    return parseInt(value, 10);
                })
            };
        }
        return { atLeast: parseInt(parts[1], 10) || 0 };
    }

    /*
     * 하나의 파일 입력을 지켜본다.
     *
     * 오류는 그 입력 바로 아래에 둔다. 화면 위쪽의 알림 줄에 띄우면 칸이 여럿일 때
     * 어느 칸 이야기인지 알 수 없다.
     */
    function watch(input) {
        var rule = parseRule(input.dataset.imageRule);
        var label = input.dataset.imageLabel || "이미지";
        var button = input.form && input.form.querySelector("button[type=submit]");

        var note = document.createElement("p");
        note.className = "field-error";
        note.hidden = true;
        input.insertAdjacentElement("afterend", note);

        input.addEventListener("change", async function () {
            var file = input.files[0];
            if (!file) {
                note.hidden = true;
                if (button) button.disabled = false;
                return;
            }

            var message;
            try {
                message = complain(await readSize(file), rule, label);
            } catch (error) {
                // 파일을 못 읽는 경우다. 여기서 막지 않고 서버에 맡긴다.
                message = null;
            }

            note.textContent = message || "";
            note.hidden = !message;
            // 누를 수 있는데 반드시 실패하는 버튼을 남기지 않는다.
            if (button) button.disabled = !!message;
        });
    }

    document.querySelectorAll("input[type=file][data-image-rule]").forEach(watch);
})();
