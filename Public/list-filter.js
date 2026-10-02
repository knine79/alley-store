/*
 * 앱 목록의 검색·정렬·분류를 고르는 즉시 반영한다 (이슈 #56).
 *
 * **거르고 늘어놓는 것은 여전히 서버가 한다.** 같은 주소를 받아 목록 자리만 갈아
 * 끼운다. 여기서 다시 거르면 규칙이 스토어 앱·서버·스크립트 세 벌이 되고, 조건이
 * 같은데 순서가 다른 날이 온다 (`CatalogFilter`).
 *
 * 스크립트가 없으면 `<noscript>` 안의 보기 버튼으로 폼을 제출하는 길이 남는다.
 */
(function () {
    "use strict";

    /* 글자마다 부르지 않는다. 치다가 멈칫한 순간에만 보낸다. */
    var QUIET_MS = 200;

    var form = document.querySelector("form.list-filter");
    var list = document.getElementById("app-list");
    var clear = document.getElementById("list-filter-clear");
    if (!form || !list || !clear || !window.fetch || !window.DOMParser) return;

    /*
     * 늦게 온 응답이 최근 결과를 덮지 않게 한다. 요청마다 번호를 매기고 마지막 것만
     * 그린다. 두 글자 전의 목록이 남는 것이 이 화면에서 가장 헷갈리는 상태다.
     */
    var latest = 0;
    var timer = null;

    /* 빈 값은 주소에 싣지 않는다. 공유한 주소가 `?q=&category=` 로 지저분해진다. */
    function currentURL() {
        var params = new URLSearchParams();
        new FormData(form).forEach(function (value, key) {
            if (String(value).trim()) params.append(key, value);
        });
        var query = params.toString();
        return form.getAttribute("action") + (query ? "?" + query : "");
    }

    function refresh() {
        clearTimeout(timer);
        var url = currentURL();
        var ticket = ++latest;
        list.setAttribute("aria-busy", "true");

        fetch(url, { credentials: "same-origin", headers: { Accept: "text/html" } })
            .then(function (response) {
                // 세션이 끊겼거나 서버가 실패했다. 갈아끼울 것이 없으니 그 주소로 간다.
                // 로그인 화면이든 오류 화면이든 사람이 이유를 본다.
                if (!response.ok || response.redirected) {
                    window.location.assign(url);
                    return null;
                }
                return response.text();
            })
            .then(function (html) {
                if (html === null || ticket !== latest) return;
                var page = new DOMParser().parseFromString(html, "text/html");
                var nextList = page.getElementById("app-list");
                var nextClear = page.getElementById("list-filter-clear");
                if (!nextList || !nextClear) {
                    window.location.assign(url);
                    return;
                }
                list.innerHTML = nextList.innerHTML;
                clear.innerHTML = nextClear.innerHTML;
                // 새로 고치거나 주소를 공유해도 같은 목록이 나와야 한다. 뒤로 가기가
                // 글자마다 쌓이지 않게 기록을 덮어쓴다.
                history.replaceState(null, "", url);
            })
            .catch(function () {
                if (ticket === latest) window.location.assign(url);
            })
            .then(function () {
                if (ticket === latest) list.removeAttribute("aria-busy");
            });
    }

    form.addEventListener("input", function (event) {
        if (event.target.name !== "q") return;
        clearTimeout(timer);
        timer = setTimeout(refresh, QUIET_MS);
    });

    form.addEventListener("change", function (event) {
        if (event.target.tagName === "SELECT") refresh();
    });

    /* 엔터는 기다리지 않고 바로 반영한다. 페이지를 다시 읽으면 칸의 커서를 잃는다. */
    form.addEventListener("submit", function (event) {
        event.preventDefault();
        refresh();
    });
})();
