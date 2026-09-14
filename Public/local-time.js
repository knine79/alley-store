/*
 * 날짜를 보는 사람의 타임존으로 다시 그린다.
 *
 * 서버가 만든 문자열은 서버 프로세스의 타임존 기준인데, 컨테이너는 보통 UTC 라
 * 화면에 뜬 시각이 보는 사람의 시계와 어긋난다. 그렇다고 서버에 타임존을 박으면
 * 다른 시간대에서 보는 사람이 또 어긋난다.
 *
 * 그래서 서버가 `<time datetime>` 에 ISO 8601 을 함께 실어 보내고, 여기서 그것을
 * 로컬 시각으로 바꾼다. **스크립트가 돌지 않아도 서버가 쓴 값이 그대로 남는다.**
 * 틀린 타임존일 뿐 빈 칸이 되지는 않는다.
 *
 * 형식은 서버(`DateStyle`)와 맞춘다. 로케일을 브라우저 것으로 두면 같은 화면에서
 * 형식이 갈리므로 `ko-KR` 로 고정하고 타임존만 로컬을 쓴다.
 */
(function () {
    "use strict";

    var DATE_ONLY = { year: "numeric", month: "numeric", day: "numeric" };
    var WITH_MINUTE = {
        year: "numeric",
        month: "numeric",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
    };

    function render(element) {
        var raw = element.getAttribute("datetime");
        if (!raw) {
            return;
        }
        var parsed = new Date(raw);
        if (isNaN(parsed.getTime())) {
            // 서버가 보낸 값이 ISO 가 아니면 건드리지 않는다. 서버가 쓴 글자가 남는
            // 편이 빈 칸보다 낫다.
            return;
        }

        var dateOnly = element.getAttribute("data-date-only") === "true";
        element.textContent = parsed.toLocaleString(
            "ko-KR",
            dateOnly ? DATE_ONLY : WITH_MINUTE
        );
        // 날짜만 보여주는 자리에서도 정확한 시각이 필요할 때가 있다.
        element.title = parsed.toLocaleString("ko-KR", WITH_MINUTE);
    }

    var elements = document.querySelectorAll("time[datetime]");
    for (var i = 0; i < elements.length; i++) {
        render(elements[i]);
    }
})();
