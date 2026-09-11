/*
 * 되돌릴 수 없는 폼 앞에서 한 번 멈춰 세운다.
 *
 * `data-confirm` 이 붙은 폼을 가로채 팝업을 띄우고, 승낙해야 보낸다. 팝업은
 * 네이티브 `<dialog>` 라서 Esc·초점 가두기·배경 가림이 딸려 온다 (ADR-0037).
 *
 * **`close` 이벤트를 믿지 않는다.** Chrome 152 헤드리스에서는 `dialog.close()` 로
 * 닫아도 `close` 가 오지 않았다. 확실히 오는 폼 `submit` 과 `cancel` 에 건다.
 *
 * 스크립트가 없으면 폼이 그대로 간다. 권한과 조건은 서버가 다시 본다.
 */
(function () {
    "use strict";

    var forms = document.querySelectorAll("form[data-confirm]");
    if (!forms.length) return;

    var dialog = document.getElementById("confirm-dialog");
    var message = document.getElementById("confirm-message");
    var accept = document.getElementById("confirm-accept");
    if (!dialog || !message || !accept) return;

    var dialogForm = dialog.querySelector("form");

    Array.prototype.forEach.call(forms, function (form) {
        form.addEventListener("submit", function (event) {
            if (form.dataset.confirmed === "1") return;
            event.preventDefault();

            ask(form.dataset.confirm, form.dataset.confirmLabel).then(function (agreed) {
                if (!agreed) return;
                // 다시 올라온 제출은 그대로 통과시킨다.
                form.dataset.confirmed = "1";
                form.submit();
            });
        });
    });

    function ask(text, label) {
        message.textContent = text;
        accept.textContent = label || "지우기";

        if (typeof dialog.showModal !== "function" || !dialogForm) {
            return Promise.resolve(window.confirm(text));
        }

        return new Promise(function (resolve) {
            function settle(agreed) {
                dialogForm.removeEventListener("submit", onSubmit);
                dialog.removeEventListener("cancel", onCancel);
                dialog.removeEventListener("close", onClose);
                if (dialog.open) dialog.close();
                resolve(agreed);
            }
            // 어느 버튼인지 모르면 하지 않는다. 되돌릴 수 없는 쪽으로 기울지 않는다.
            function onSubmit(event) {
                settle(!!event.submitter && event.submitter.value === "accept");
            }
            function onCancel() { settle(false); }
            function onClose() { settle(dialog.returnValue === "accept"); }

            dialog.returnValue = "";
            dialogForm.addEventListener("submit", onSubmit);
            dialog.addEventListener("cancel", onCancel);
            dialog.addEventListener("close", onClose);
            dialog.showModal();
        });
    }
})();
