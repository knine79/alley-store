/*
 * 바뀐 것이 없으면 저장 버튼을 누를 수 없게 한다.
 *
 * 고칠 것이 없는데 누를 수 있는 버튼은 두 가지를 망친다. 눌러도 아무 일이 없으니
 * 눌렀는지 아닌지 알 수 없고, "저장했습니다" 가 뜨면 바꾼 적 없는 것을 바꾼 줄
 * 안다. 역할 변경처럼 줄마다 버튼이 있는 화면에서는 어느 줄을 건드렸는지도 흐려진다.
 *
 * **고치는 폼에만 붙인다.** 발급·폐기·출시처럼 값을 고치는 것이 아니라 일을 시키는
 * 버튼은 언제나 누를 수 있어야 한다. 그래서 자동으로 걸지 않고 `data-guard-dirty`
 * 를 단 폼만 본다.
 *
 * 스크립트가 없으면 예전처럼 언제나 누를 수 있다. 그때 바뀐 것 없이 저장하면 서버가
 * 같은 값을 다시 쓸 뿐이라 잘못되는 것은 없다.
 */
(function () {
    "use strict";

    /** 이 칸의 지금 값. 종류마다 "바뀌었나" 의 뜻이 다르다. */
    function valueOf(field) {
        if (field.type === "checkbox" || field.type === "radio") {
            return field.checked ? "1" : "0";
        }
        if (field.type === "file") {
            // 파일은 고른 순간이 곧 바뀐 것이다. 이름까지 보는 이유는 같은 칸에서
            // 다른 파일로 바꿔 고르는 경우를 잡기 위해서다.
            return field.files && field.files.length ? field.files[0].name : "";
        }
        return field.value;
    }

    /** 폼에 딸린 칸들. `form` 속성으로 폼 밖에 있는 것도 여기 들어온다. */
    function fieldsOf(form) {
        return Array.prototype.filter.call(form.elements, function (field) {
            if (!field.name) return false;
            return field.tagName === "INPUT"
                || field.tagName === "SELECT"
                || field.tagName === "TEXTAREA";
        });
    }

    function guard(form) {
        var button = form.querySelector("button[type=submit]");
        if (!button) return;

        var fields = fieldsOf(form);
        if (fields.length === 0) return;

        var initial = fields.map(valueOf);

        function changed() {
            return fields.some(function (field, index) {
                return valueOf(field) !== initial[index];
            });
        }

        function sync() {
            button.disabled = !changed();
        }

        // **칸마다 따로 듣는다.** 폼에 한 번 거는 것으로는 모자란다.
        //
        // `form` 속성으로 폼에 딸린 칸은 DOM 상으로는 폼 **밖에** 있다. 스토어 설정의
        // 이름과 강조색이 그렇다(카드 구조 때문에 폼 밖에 둔다). 그 칸의 이벤트는
        // 폼까지 올라오지 않아서, 폼에만 걸면 그 둘을 고쳐도 버튼이 잠긴 채였다.
        //
        // `change` 만 듣지 않는 이유는 그것이 칸을 벗어날 때 오기 때문이다. 글자를
        // 적어두고 버튼으로 바로 가면 그 사이에 버튼이 아직 잠겨 있다.
        fields.forEach(function (field) {
            field.addEventListener("input", sync);
            field.addEventListener("change", sync);
        });

        sync();
    }

    // **오류로 돌아온 화면에서는 걸지 않는다.**
    //
    // 서버가 거절하면 적었던 값을 그대로 채워 다시 그린다. 그 값이 곧 "처음 값" 이
    // 되어버려서, 고칠 곳을 찾지 못한 사람은 다시 눌러볼 수조차 없게 된다.
    if (document.querySelector(".notice-error")) return;

    document.querySelectorAll("form[data-guard-dirty]").forEach(guard);
})();
