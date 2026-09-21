/*
 * 알림 대상을 만들 때, 고른 방식에 칸을 맞춘다.
 *
 * Slack 웹훅 주소와 메일 주소는 생긴 것도 구하는 곳도 다르다. 둘을 아우르는 말로
 * 적으면 어느 쪽에도 맞지 않는 안내가 되고, 예시 하나에 둘을 붙여 놓으면 어느
 * 쪽을 넣어야 하는지 다시 읽어야 한다.
 *
 * **바뀔 말은 이 파일에 없다.** `<option>` 의 `data-` 에 있다. 스크립트가 한국어를
 * 들고 있으면 화면 문구를 다듬을 때 이쪽이 조용히 뒤처진다.
 *
 * 스크립트가 없으면 칸은 둘 다 그대로 서고 말은 둘을 아우르는 것으로 남는다.
 * 서버가 무엇을 받았는지 보고 거절하므로 틀린 값이 들어가지는 않는다.
 */
(function () {
    "use strict";

    function setup(select) {
        var form = select.form;
        if (!form) return;

        var endpointField = form.querySelector("[data-endpoint-field]");
        var nameField = form.querySelector("[data-name-field]");
        if (!endpointField) return;

        var label = endpointField.querySelector(".field-label");
        var input = endpointField.querySelector("input");
        var note = endpointField.querySelector(".field-note");
        var nameInput = nameField ? nameField.querySelector("input") : null;

        var nameLabel = nameField ? nameField.querySelector(".field-label") : null;
        var nameNote = nameField ? nameField.querySelector(".field-note") : null;

        function apply() {
            var option = select.options[select.selectedIndex];
            if (!option) return;

            if (label) label.textContent = option.getAttribute("data-endpoint-label");
            if (note) note.textContent = option.getAttribute("data-endpoint-note");
            if (input) input.placeholder = option.getAttribute("data-endpoint-placeholder");

            /*
             * 이름 칸도 방식마다 뜻이 다르다. 웹훅은 보이지 않는 주소를 대신할
             * 이름이고, 메일은 그 주소가 누구인지다. 둘 다 받지만 묻는 말이 다르다.
             */
            if (nameLabel) nameLabel.textContent = option.getAttribute("data-name-label");
            if (nameNote) nameNote.textContent = option.getAttribute("data-name-note");
            if (nameInput) nameInput.placeholder = option.getAttribute("data-name-placeholder");
        }

        select.addEventListener("change", apply);
        apply();
    }

    function start() {
        var selects = document.querySelectorAll("[data-target-kind]");
        for (var i = 0; i < selects.length; i += 1) setup(selects[i]);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start);
    } else {
        start();
    }
})();
