/*
 * Slack 채널을 고르는 순간 채널 등록 칸을 연다.
 *
 * 서버가 저장된 값으로 한 번 정해두고, 여기서는 라디오를 누르는 순간 열고 닫기만
 * 한다. 스크립트가 없으면 저장을 누른 뒤에 열린다 - 늦을 뿐이지 막히지 않는다.
 *
 * 빌드 스텝 없이 브라우저가 그대로 읽는다. CSP 가 `script-src 'self'` 라 CDN 에서
 * 아무것도 못 받는다.
 */
(function () {
    "use strict";

    function setup(group) {
        /*
         * 칸은 이 묶음 밖에 있다. 채널 등록 칸이 그 자체로 폼이라 고르는 폼 안에
         * 넣을 수 없어서(폼은 중첩되지 않는다) 폼을 라디오에서 끊었기 때문이다.
         * 그래서 형제가 아니라 문서 전체에서 찾는다.
         */
        var form = group.form;
        var root = form ? form.parentNode : document;
        var channels = root.querySelector("[data-alert-channels]");
        if (!channels) return;

        function apply() {
            var chosen = group.querySelector("input[name='target']:checked");
            channels.hidden = !chosen || chosen.value !== "channel";
        }

        var radios = group.querySelectorAll("input[name='target']");
        for (var i = 0; i < radios.length; i += 1) {
            radios[i].addEventListener("change", apply);
        }
        apply();
    }

    function start() {
        var groups = document.querySelectorAll("[data-alert-choice]");
        for (var i = 0; i < groups.length; i += 1) setup(groups[i]);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start);
    } else {
        start();
    }
})();
