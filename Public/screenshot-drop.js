// 스크린샷 올리기 상자.
//
// 폼은 스크립트 없이도 간다. 여기서 하는 일은 둘뿐이다. 파일을 상자 위로 끌어오는 동안
// 놓아도 되는 자리라는 것을 보이고, 고르거나 놓자마자 "올리기" 를 누르지 않아도 올린다.
//
// 놓는 것 자체는 브라우저가 한다. 상자를 덮은 파일 칸 위에 놓으면 그 칸에 들어간다.
(function () {
    "use strict";

    document.querySelectorAll("form[data-screenshot-upload]").forEach(function (form) {
        var zone = form.querySelector(".dropzone");
        var input = form.querySelector('input[type="file"]');
        if (!zone || !input) return;

        ["dragenter", "dragover"].forEach(function (type) {
            zone.addEventListener(type, function () {
                zone.classList.add("dropzone-armed");
            });
        });
        ["dragleave", "drop"].forEach(function (type) {
            zone.addEventListener(type, function () {
                zone.classList.remove("dropzone-armed");
            });
        });

        input.addEventListener("change", function () {
            if (!input.files || input.files.length === 0) return;
            // 올리는 동안 다시 놓으면 어느 것이 올라가는지 알 수 없게 된다.
            zone.classList.add("dropzone-locked");
            var title = zone.querySelector(".dropzone-title");
            if (title) title.textContent = input.files.length + "장을 올리는 중입니다…";
            form.submit();
        });
    });
})();
