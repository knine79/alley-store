/*
 * 업로드 권한 줄 사람을 치는 동안 찾는다.
 *
 * **서버가 그리던 것을 대신하지 않는다.** 폼은 그대로 있고 제출하면 서버가 같은
 * 결과를 HTML 로 그린다. 여기는 그 왕복을 기다리지 않고 같은 것을 먼저 보여줄
 * 뿐이다. 스크립트가 없거나 실패하면 찾기 버튼을 누르는 예전 길이 그대로 남는다.
 *
 * 빌드 스텝 없이 브라우저가 그대로 읽는다. CSP 가 `script-src 'self'` 라 CDN 에서
 * 아무것도 못 받는다.
 */
(function () {
    "use strict";

    /*
     * 한 글자마다 부르지 않는다. 사람이 이름을 치는 속도로는 글자마다 요청이 나가고,
     * 먼저 보낸 것이 나중에 도착해 엉뚱한 결과가 남는다. 멈칫하는 순간에만 보낸다.
     */
    var QUIET_MS = 180;

    /* 이보다 짧으면 부르지 않는다. 한 글자로는 거의 모두가 걸려서 고를 것이 없다. */
    var MIN_LENGTH = 2;

    function setup(form) {
        var input = form.querySelector("input[name='member']");
        var url = form.getAttribute("data-candidates-url");
        var list = document.getElementById(form.getAttribute("data-results"));
        if (!input || !url || !list) return;

        /*
         * 늦게 온 응답이 최근 결과를 덮지 않게 한다. 요청마다 번호를 매기고 마지막
         * 것만 그린다. 네트워크가 느린 순간에 두 글자 전의 목록이 남는 것이 이
         * 화면에서 가장 헷갈리는 상태다.
         */
        var latest = 0;
        var timer = null;

        /* 서버가 그린 결과가 이미 있으면 그것을 지운다. 둘이 겹쳐 서면 안 된다. */
        var serverRendered = document.getElementById(form.getAttribute("data-server-results"));

        function render(payload, query) {
            list.innerHTML = "";
            if (serverRendered) serverRendered.hidden = true;

            if (!query) return;

            if (!payload.candidates.length) {
                var empty = document.createElement("p");
                empty.className = "empty";
                // 빈 결과의 이유가 둘이다. 한쪽만 적으면 이미 권한이 있는 사람을
                // 찾다가 "로그인한 적이 없나" 로 잘못 짚는다.
                empty.textContent =
                    "'" + query + "' 로 찾은 사람이 없습니다. 이미 올릴 수 있는 사람과, " +
                    "이 스토어에 아직 한 번도 로그인한 적이 없는 사람은 나오지 않습니다.";
                list.appendChild(empty);
                return;
            }

            var people = document.createElement("ul");
            people.className = "person-list";
            payload.candidates.forEach(function (candidate) {
                people.appendChild(row(candidate));
            });
            list.appendChild(people);

            if (payload.overflowed) {
                var note = document.createElement("p");
                note.className = "field-note";
                note.textContent = "결과가 많아 일부만 보입니다. 더 좁혀서 찾아보세요.";
                list.appendChild(note);
            }
        }

        /*
         * 서버가 그리는 줄과 같은 모양으로 만든다. 스크립트가 있을 때와 없을 때
         * 화면이 달라지면 둘 중 하나는 손볼 때마다 잊힌다.
         *
         * `textContent` 로만 넣는다. 이름과 이메일은 사람이 적은 값이라 HTML 로
         * 붙이면 그대로 실행된다.
         */
        function row(candidate) {
            var item = document.createElement("li");
            item.className = "person";

            var name = document.createElement("span");
            name.className = "person-name";
            name.textContent = candidate.name;

            var email = document.createElement("span");
            email.className = "person-email";
            email.textContent = candidate.email;

            var grant = document.createElement("form");
            grant.className = "person-action";
            grant.method = "post";
            grant.action = form.getAttribute("data-grant-url");

            var id = document.createElement("input");
            id.type = "hidden";
            id.name = "userID";
            id.value = candidate.id;

            var button = document.createElement("button");
            button.className = "button button-small";
            button.type = "submit";
            button.textContent = "권한 주기";

            grant.appendChild(id);
            grant.appendChild(button);
            item.appendChild(name);
            item.appendChild(email);
            item.appendChild(grant);
            return item;
        }

        function search() {
            var query = input.value.trim();
            if (query.length < MIN_LENGTH) {
                render({ candidates: [], overflowed: false }, "");
                return;
            }

            var mine = ++latest;
            fetch(url + "?q=" + encodeURIComponent(query), {
                credentials: "same-origin",
                headers: { Accept: "application/json" }
            })
                .then(function (response) {
                    if (!response.ok) throw new Error(response.status);
                    return response.json();
                })
                .then(function (payload) {
                    if (mine !== latest) return;
                    render(payload, query);
                })
                .catch(function () {
                    // **조용히 물러난다.** 찾기 버튼이 그대로 있으므로 사람은 그것을
                    // 누르면 된다. 여기서 오류를 띄우면 고칠 수도 없는 말이 뜬다.
                    if (mine !== latest) return;
                    list.innerHTML = "";
                });
        }

        input.addEventListener("input", function () {
            if (timer) clearTimeout(timer);
            timer = setTimeout(search, QUIET_MS);
        });

        /*
         * 결과가 뜬 채로 엔터를 치면 폼이 제출돼 화면이 통째로 다시 그려진다.
         * 이미 보고 있는 것을 다시 받으려고 왕복하는 셈이라 막는다. 버튼은 그대로
         * 두고, 누르면 예전처럼 서버가 그린다.
         */
        form.addEventListener("submit", function (event) {
            if (input.value.trim().length >= MIN_LENGTH) {
                event.preventDefault();
                if (timer) clearTimeout(timer);
                search();
            }
        });

        // 되돌아온 화면에 검색어가 남아 있으면 그 결과부터 보여준다.
        if (input.value.trim().length >= MIN_LENGTH) search();
    }

    function start() {
        var forms = document.querySelectorAll("[data-candidates-url]");
        for (var i = 0; i < forms.length; i += 1) setup(forms[i]);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start);
    } else {
        start();
    }
})();
