/*
 * 출시 버튼 앞에서 출시 소식을 알릴지 묻는다 (ADR-0075).
 *
 * `data-release` 가 붙은 폼을 가로채 팝업을 띄운다. 고른 버튼에 따라 폼의
 * `announce` 칸을 채워 보낸다.
 *
 * - cancel: 아무것도 하지 않는다
 * - release: 알리지 않고 출시한다
 * - announce: 출시하고 알린다
 * - setup: 출시하지 않고 출시 소식 알림 섹션으로 간다
 *
 * **`close` 이벤트를 믿지 않는다.** `confirm.js` 와 같은 이유다. 확실히 오는 폼
 * `submit` 과 `cancel` 에 건다.
 *
 * 스크립트가 없으면 폼이 그대로 가고, `announce` 가 비어 있어 알리지 않는다.
 */
(function () {
    "use strict";

    var forms = document.querySelectorAll("form[data-release]");
    if (!forms.length) return;

    var dialog = document.getElementById("release-dialog");
    if (!dialog) return;
    var dialogForm = dialog.querySelector("form");
    // 지금 열린 팝업을 끝낼 함수. 새로 열 때 앞의 것을 먼저 끝낸다.
    //
    // Esc 가 `cancel` 없이 팝업을 닫는 브라우저가 있다. 그러면 앞 줄의 기다림이 남아,
    // 다음 줄에서 고른 버튼에 앞 줄의 폼까지 함께 제출된다.
    var pending = null;

    // 뒤로 가기로 돌아온 화면은 스크립트 상태를 그대로 갖고 온다. 한 번 지나간 폼이
    // 팝업 없이, 앞서 고른 값으로 다시 가지 않게 지운다.
    window.addEventListener("pageshow", function () {
        Array.prototype.forEach.call(forms, function (form) {
            delete form.dataset.confirmed;
        });
    });

    Array.prototype.forEach.call(forms, function (form) {
        form.addEventListener("submit", function (event) {
            if (form.dataset.confirmed === "1") return;
            event.preventDefault();

            ask(form).then(function (choice) {
                if (choice === "setup") {
                    var section = document.getElementById("release-news");
                    if (section) section.scrollIntoView();
                    location.hash = "release-news";
                    return;
                }
                if (choice !== "release" && choice !== "announce") return;

                var carrier = form.querySelector('input[name="announce"]');
                if (carrier) carrier.value = choice === "announce" ? "1" : "";
                form.dataset.confirmed = "1";
                form.submit();
            });
        });
    });

    function fill(selector, text) {
        Array.prototype.forEach.call(dialog.querySelectorAll(selector), function (node) {
            node.textContent = text;
        });
    }

    function ask(form) {
        var short = form.dataset.release || "";
        var build = form.dataset.releaseBuild;
        fill("[data-release-short]", short);
        fill("[data-release-full]", build ? short + " (" + build + ")" : short);

        if (typeof dialog.showModal !== "function" || !dialogForm) {
            // 팝업을 못 띄우는 브라우저. 알릴지 고를 방법이 없으니 알리지 않고 출시만 묻는다.
            return Promise.resolve(window.confirm(short + " 를 출시할까요?") ? "release" : "cancel");
        }

        if (pending) pending("cancel");

        return new Promise(function (resolve) {
            function settle(choice) {
                dialogForm.removeEventListener("submit", onSubmit);
                dialog.removeEventListener("cancel", onCancel);
                if (pending === settle) pending = null;
                if (dialog.open) dialog.close();
                resolve(choice);
            }
            pending = settle;
            // 어느 버튼인지 모르면 하지 않는다.
            function onSubmit(event) {
                settle(event.submitter ? event.submitter.value : "cancel");
            }
            function onCancel() { settle("cancel"); }

            dialog.returnValue = "";
            dialogForm.addEventListener("submit", onSubmit);
            dialog.addEventListener("cancel", onCancel);
            dialog.showModal();
        });
    }
})();
