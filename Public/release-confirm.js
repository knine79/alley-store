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
 * 알리지 않고 출시한 버전의 "출시 소식 보내기" 도 여기서 묻는다 (이슈 #81, ADR-0082).
 * `data-announce` 가 붙은 폼이고, `send` 를 고르면 `send` 칸을 채워 보낸다.
 *
 * **setup 은 하던 버전을 들고 간다.** 채널 칸의 `resume` 에 버전 ID 를 넣어 두면,
 * 등록에 성공한 서버가 `?resume=<ID>` 로 돌려보내고 여기서 그 버전의 팝업을 다시
 * 띄운다. 채널을 넣고 나서 하던 버전을 다시 찾아 누르지 않아도 된다.
 *
 * **`close` 이벤트를 믿지 않는다.** `confirm.js` 와 같은 이유다. 확실히 오는 폼
 * `submit` 과 `cancel` 에 건다.
 *
 * 스크립트가 없으면 폼이 그대로 가고, `announce` 와 `send` 가 비어 있어 알리지 않는다.
 */
(function () {
    "use strict";

    // 지금 열린 팝업을 끝낼 함수. 새로 열 때 앞의 것을 먼저 끝낸다.
    //
    // Esc 가 `cancel` 없이 팝업을 닫는 브라우저가 있다. 그러면 앞 줄의 기다림이 남아,
    // 다음 줄에서 고른 버튼에 앞 줄의 폼까지 함께 제출된다.
    var pending = null;

    var kinds = [
        {
            selector: "form[data-release]",
            dialog: document.getElementById("release-dialog"),
            carrier: "announce",
            // 고른 값 → 칸에 넣을 값. 없는 값은 보내지 않는다.
            submits: { release: "", announce: "1" },
            label: function (form) { return form.dataset.release || ""; },
            build: function (form) { return form.dataset.releaseBuild; },
            fallback: function (short) {
                // 팝업을 못 띄우는 브라우저. 알릴지 고를 방법이 없으니 알리지 않고 출시만 묻는다.
                return window.confirm(short + " 를 출시할까요?") ? "release" : "cancel";
            }
        },
        {
            selector: "form[data-announce]",
            dialog: document.getElementById("announce-dialog"),
            carrier: "send",
            submits: { send: "1" },
            label: function (form) { return form.dataset.announce || ""; },
            build: function (form) { return form.dataset.announceBuild; },
            fallback: function (short) {
                // 채널이 없으면 팝업에도 보내기 단추가 없다. 보내 봐야 실패하니 등록하러 간다.
                if (!this.dialog.querySelector('button[value="send"]')) {
                    return window.confirm("출시 소식을 올릴 채널이 없습니다. 채널을 등록하러 갈까요?")
                        ? "setup" : "cancel";
                }
                return window.confirm(short + " 의 출시 소식을 보낼까요?") ? "send" : "cancel";
            }
        }
    ];

    var forms = [];
    kinds.forEach(function (kind) {
        if (!kind.dialog) return;
        Array.prototype.forEach.call(document.querySelectorAll(kind.selector), function (form) {
            forms.push(form);
            form.addEventListener("submit", function (event) {
                if (form.dataset.confirmed === "1") return;
                event.preventDefault();
                run(kind, form);
            });
        });
    });
    if (!forms.length) return;

    // 뒤로 가기로 돌아온 화면은 스크립트 상태를 그대로 갖고 온다. 한 번 지나간 폼이
    // 팝업 없이, 앞서 고른 값으로 다시 가지 않게 지운다.
    window.addEventListener("pageshow", function () {
        forms.forEach(function (form) { delete form.dataset.confirmed; });
    });

    resume();

    function run(kind, form) {
        ask(kind, form).then(function (choice) {
            if (choice === "setup") {
                setup(form);
                return;
            }
            if (!Object.prototype.hasOwnProperty.call(kind.submits, choice)) return;

            var carrier = form.querySelector('input[name="' + kind.carrier + '"]');
            if (carrier) carrier.value = kind.submits[choice];
            form.dataset.confirmed = "1";
            form.submit();
        });
    }

    function setup(form) {
        var carrier = document.querySelector('#release-channel-form input[name="resume"]');
        if (carrier) carrier.value = form.dataset.releaseVersion || "";
        var section = document.getElementById("release-news");
        if (section) section.scrollIntoView();
        location.hash = "release-news";
        var input = document.querySelector('#release-channel-form input[name="channel"]');
        if (input) input.focus();
    }

    /** 채널을 등록하고 돌아왔으면 하던 버전의 팝업을 다시 띄운다. */
    function resume() {
        if (!window.URL) return;
        var url = new URL(window.location.href);
        var id = url.searchParams.get("resume");
        if (!id) return;

        // 새로고침해서 또 뜨지 않게 주소에서 먼저 걷어낸다.
        url.searchParams.delete("resume");
        if (window.history && window.history.replaceState) {
            window.history.replaceState(
                window.history.state, "", url.pathname + url.search + url.hash
            );
        }

        // 그 사이에 출시됐거나 이미 알렸으면 맞는 폼이 없다. 그때는 띄우지 않는다.
        for (var i = 0; i < kinds.length; i++) {
            var kind = kinds[i];
            if (!kind.dialog) continue;
            var matches = Array.prototype.filter.call(
                document.querySelectorAll(kind.selector),
                function (form) { return form.dataset.releaseVersion === id; }
            );
            if (matches.length) {
                run(kind, matches[0]);
                return;
            }
        }
    }

    function fill(dialog, selector, text) {
        Array.prototype.forEach.call(dialog.querySelectorAll(selector), function (node) {
            node.textContent = text;
        });
    }

    function ask(kind, form) {
        var dialog = kind.dialog;
        var dialogForm = dialog.querySelector("form");
        var short = kind.label(form);
        var build = kind.build(form);
        var full = build ? short + " (" + build + ")" : short;
        fill(dialog, "[data-release-short]", short);
        fill(dialog, "[data-release-full]", full);
        fill(dialog, "[data-announce-full]", full);

        if (typeof dialog.showModal !== "function" || !dialogForm) {
            return Promise.resolve(kind.fallback(short));
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
