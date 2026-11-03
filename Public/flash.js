/*
 * 한 번만 보여줄 표시를 한 번만 보여준다.
 *
 * 저장하고 나면 서버가 `?saved=1` 을 붙여 같은 화면으로 돌려보낸다. 그 표시를 읽어
 * "저장했습니다" 를 띄우는데, **표시가 주소에 남아 있어서** 새로고침하든 뒤로 갔다
 * 오든 같은 줄이 다시 뜬다. 방금 저장한 것이 아닌데 방금 저장한 것처럼 보이고,
 * 한 번 뜨면 그 탭에서는 없앨 방법이 없다.
 *
 * 그려진 뒤에 주소에서 걷어낸다. 화면에는 그대로 있고, 다시 불러오면 없다.
 * 주소만 바꾸므로 뒤로 가기 기록도 늘어나지 않는다 (`replaceState`).
 *
 * `data-toast` 가 붙은 줄은 토스트로 옮긴다. "저장했습니다" 처럼 읽고 나면 할 일이
 * 없는 한 줄이다. 화면 위쪽 구석에 떴다가 몇 초 뒤 비켜주고, 마우스나 초점이 머무는
 * 동안은 기다린다. 제자리에 두면 아래 내용을 밀어내고, 사라질 때 내용이 덜컥 올라온다.
 *
 * **나머지 줄은 남긴다.** 오류는 읽고 나서 할 일이 있다. 발급한 토큰이나 다음에 할 일을
 * 적은 안내도 그렇다. 사라지면 다시 알아낼 방법이 없다. 스크립트가 없으면 토스트도
 * 제자리에 그대로 남는다.
 */
(function () {
    "use strict";

    /** 서버가 한 번만 쓰라고 붙이는 것들. */
    var ONE_SHOT = ["saved", "error", "built", "released", "announced", "sent", "announce_failed"];

    /** 토스트가 머무는 시간. 한 문장을 읽고도 남는 길이다. */
    var LINGER_MS = 6000;

    function stripQuery() {
        if (!window.history || !window.history.replaceState || !window.URL) return;

        var url = new URL(window.location.href);
        var changed = false;
        ONE_SHOT.forEach(function (key) {
            if (url.searchParams.has(key)) {
                url.searchParams.delete(key);
                changed = true;
            }
        });
        if (!changed) return;

        window.history.replaceState(
            window.history.state, "", url.pathname + url.search + url.hash
        );
    }

    function toast(notice, stack) {
        notice.classList.add("toast");
        stack.appendChild(notice);

        var timer = null;
        var paused = false;
        function leave() {
            notice.classList.add("notice-leaving");
            window.setTimeout(function () { notice.remove(); }, 400);
        }
        function wait() {
            if (timer) window.clearTimeout(timer);
            timer = window.setTimeout(function () { if (!paused) leave(); }, LINGER_MS);
        }
        // 읽는 중에는 기다린다. 손을 떼면 처음부터 다시 센다.
        function pause() { paused = true; if (timer) window.clearTimeout(timer); }
        function resume() { paused = false; wait(); }
        notice.addEventListener("mouseenter", pause);
        notice.addEventListener("mouseleave", resume);
        notice.addEventListener("focusin", pause);
        notice.addEventListener("focusout", resume);
        wait();
    }

    stripQuery();
    var toasts = document.querySelectorAll("[data-toast]");
    if (toasts.length) {
        var stack = document.createElement("div");
        stack.className = "toast-stack";
        // 화면 읽기 프로그램이 옮겨진 줄을 읽어 준다.
        stack.setAttribute("role", "status");
        stack.setAttribute("aria-live", "polite");
        // 머리 막대 바로 아래에 둔다. 좁은 화면에서는 메뉴가 두 줄이 되어 높이가 바뀌므로
        // 띄우는 순간에 잰다. 머리 막대는 따라 내려오지 않아서, 스크롤하면 위로 붙는다.
        var chrome = document.querySelector(".chrome");
        if (chrome) {
            var below = Math.max(chrome.getBoundingClientRect().bottom, 0);
            stack.style.top = "calc(" + Math.round(below) + "px + var(--space-3))";
        }
        document.body.appendChild(stack);
        toasts.forEach(function (notice) { toast(notice, stack); });
    }
})();
