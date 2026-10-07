/*
 * 버튼을 누르면 옆의 글을 복사한다 (이슈 #64).
 *
 * `data-copy` 에 복사할 요소의 id 를 적는다. 복사하면 잠시 "복사했습니다" 로 바꿔
 * 눌렀다는 것을 알린다. 아무 표시가 없으면 됐는지 몰라 다시 누르거나 손으로 긁는다.
 *
 * **클립보드가 막혀 있으면 글을 골라 둔다.** 사내망의 http 주소처럼 보안 문맥이
 * 아니면 `navigator.clipboard` 가 없다. 그때는 글을 선택해 두고 ⌘C 를 누르라고 한다.
 *
 * 스크립트가 없으면 버튼은 아무 일도 하지 않고, 주소는 그대로 보이니 손으로 복사하면 된다.
 */
(function () {
    "use strict";

    /** "복사했습니다" 가 머무는 시간. 읽고 다시 누를 수 있게 짧게 둔다. */
    var RESET_MS = 2000;

    Array.prototype.forEach.call(document.querySelectorAll("[data-copy]"), function (button) {
        var source = document.getElementById(button.dataset.copy);
        if (!source) return;
        var label = button.textContent;
        var timer = null;

        button.addEventListener("click", function () {
            var text = source.textContent.trim();
            copy(text).then(
                function () { show("복사했습니다"); },
                function () {
                    select(source);
                    show("⌘C 로 복사하세요");
                }
            );
        });

        function show(text) {
            button.textContent = text;
            window.clearTimeout(timer);
            timer = window.setTimeout(function () { button.textContent = label; }, RESET_MS);
        }
    });

    function copy(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }
        return Promise.reject(new Error("클립보드를 쓸 수 없습니다"));
    }

    function select(node) {
        var range = document.createRange();
        range.selectNodeContents(node);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
    }
})();
