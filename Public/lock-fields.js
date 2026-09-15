/*
 * "바꾸겠습니다" 를 켜야 풀리는 칸.
 *
 * 되돌리기 어려운 값(스토어 앱의 번들 ID·URL 스킴)이 실수로 바뀌지 않게 잠가둔다.
 *
 * **잠그는 것은 서버가 아니라 여기다.** 예전에는 서버가 `readonly` 를 박아서
 * 내보냈는데, 그것을 풀어주는 코드가 없어서 확인을 켜도 칸이 그대로 잠겨 있었다.
 * 아무것도 바꿀 수 없으니 확인할 것도 없었고, 체크박스는 눌러도 아무 일이 없는
 * 장식이 됐다.
 *
 * 그래서 순서를 뒤집었다. 서버는 그냥 고칠 수 있는 칸을 내보내고, 스크립트가
 * 그 위에 잠금을 얹는다. 스크립트가 없으면 칸은 처음부터 고칠 수 있고, 확인
 * 없이 바꾼 것은 서버가 거절한다 (`StoreAppPagesController.apply`). 어느 쪽이든
 * 막히는 자리는 같고, 다른 것은 얼마나 일찍 알려주느냐뿐이다.
 *
 * 반대 방향도 같은 자리에서 다룬다. 확인을 켜는 순간 **뜻을 잃는** 칸이 있다.
 * "누구나 로그인할 수 있게 하겠습니다" 를 켜면 허용 도메인은 더 볼 것이 없는데,
 * 그 칸이 그대로 고칠 수 있게 남아 있으면 적어 넣게 되고 적은 것은 무시된다.
 * 그때는 칸을 비우고 끈다. `disabled` 라 전송되지 않고, 서버가 보는 것도 "비었다"
 * 여서 화면과 저장되는 값이 어긋나지 않는다.
 *
 * 마크업
 *   <input data-lock-group="identity">          확인을 켜야 고칠 수 있다
 *   <input type="checkbox" data-unlocks="identity">
 *
 *   <input data-lock-group="domains">           확인을 켜면 뜻을 잃는다
 *   <input type="checkbox" data-disables="domains">
 */
(function () {
    "use strict";

    function setUp(toggle) {
        var group = toggle.dataset.unlocks || toggle.dataset.disables;
        // 켜면 풀리는가, 켜면 꺼지는가.
        var disables = toggle.dataset.disables !== undefined;
        var fields = Array.prototype.slice.call(
            document.querySelectorAll('[data-lock-group="' + group + '"]')
        );
        if (fields.length === 0) return;

        // 잠그기 전의 값. 확인을 도로 끄면 여기로 되돌린다.
        //
        // 되돌리지 않으면 "고쳤다가 마음을 바꿔 확인을 끈" 상태가 남는다. 화면에는
        // 새 값이 보이고 확인은 꺼져 있으니, 저장을 누르면 서버가 거절한다. 무엇을
        // 되돌려야 하는지는 그때 사람이 기억해내야 한다.
        var original = fields.map(function (field) {
            return field.value;
        });

        function apply(checked, moveFocus) {
            fields.forEach(function (field, index) {
                if (disables) {
                    // 뜻을 잃은 칸은 비우고 끈다. 비우지 않고 끄기만 하면 화면에는
                    // 값이 남아 있는데 저장되는 것은 빈 값이라, 무엇이 저장됐는지를
                    // 화면에서 읽을 수 없다.
                    field.value = checked ? "" : original[index];
                    field.disabled = checked;
                } else {
                    if (!checked) field.value = original[index];
                    field.readOnly = !checked;
                }
            });
            // 풀어놓고 커서를 옮기지 않으면 어디를 고치라는 것인지 한 번 더 찾는다.
            // 화면을 처음 그릴 때는 옮기지 않는다. 그때 초점이 튀면 맨 위부터 읽던
            // 사람이 화면 중간으로 끌려간다.
            if (moveFocus && checked && !disables) fields[0].focus();
        }

        // 서버가 오류로 되돌려준 화면에서는 확인이 켜진 채로 온다. 그때 다시 잠그면
        // 방금 적은 것을 또 풀어야 한다.
        apply(toggle.checked, false);

        // **라디오는 자기가 꺼질 때 `change` 를 내지 않는다.** 같은 묶음의 다른
        // 쪽이 켜질 때만 그쪽에서 난다. 이것 하나만 지켜보면 "제한하지 않겠다" 에서
        // 다시 돌아와도 칸이 꺼진 채로 남는다. 묶음 전체를 지켜본다.
        var group = toggle.type === "radio" && toggle.name
            ? document.querySelectorAll('input[type=radio][name="' + toggle.name + '"]')
            : [toggle];

        Array.prototype.forEach.call(group, function (input) {
            input.addEventListener("change", function () {
                apply(toggle.checked, true);
            });
        });
    }

    document
        .querySelectorAll("[data-unlocks], [data-disables]")
        .forEach(setUp);
})();
