/*
 * 새로고침이 폼을 다시 보내지 않게 한다.
 *
 * 토큰 발급은 리다이렉트하지 않는다. 토큰 원문은 그 응답에만 있고 서버는 해시만
 * 갖고 있어서, 다음 화면에서 다시 보여줄 방법이 없기 때문이다(ADR-0013). 그래서
 * 브라우저에는 POST 한 자리가 그대로 남고, 새로고침하거나 뒤로 갔다 오면 같은 폼이
 * 다시 제출된다. **그렇게 생긴 토큰이 목록에 한 줄 더 생긴다.** 이름이 같으니
 * 폐기했던 토큰이 되살아난 것처럼 보인다.
 *
 * 그려진 뒤에 주소를 목록 주소로 바꾼다. 화면은 그대로 있어서 방금 발급한 토큰을
 * 계속 볼 수 있고, 다시 불러오면 POST 가 아니라 목록을 GET 한다. 주소만 바꾸므로
 * 뒤로 가기 기록도 늘지 않는다 (`replaceState`, `flash.js` 와 같은 방법).
 *
 * **이것이 없어도 같은 이름으로 토큰이 두 개 생기지는 않는다.** 서버가 쓸 수 있는
 * 토큰 중 같은 이름이 있으면 발급을 거절한다. 여기서 막는 것은 그 거절 화면을
 * 보게 되는 일이다.
 */
(function () {
    "use strict";

    var marker = document.querySelector("[data-resubmit-guard]");
    if (!marker) return;
    if (!window.history || !window.history.replaceState) return;

    var path = marker.getAttribute("data-resubmit-guard");
    if (!path) return;

    window.history.replaceState(window.history.state, "", path);
})();
