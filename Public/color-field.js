/*
 * 색을 눈으로 고른다.
 *
 * 강조색은 화면 곳곳에 쓰이는데 칸은 `#3b6fd4` 를 손으로 적는 자리 하나뿐이었다.
 * 무슨 색인지 알려면 저장하고 화면을 봐야 했고, 마음에 안 들면 다시 적고 다시
 * 저장해야 했다.
 *
 * **글자 칸을 없애지는 않는다.** 서버는 `#RGB`·`#RRGGBB`·`#RRGGBBAA` 를 받는데
 * 브라우저의 색 고르개는 `#RRGGBB` 만 다룬다. 투명도를 준 색을 쓰던 조직이 화면을
 * 열었다가 저장만 눌러도 투명도가 날아가면 안 된다. 그래서 진짜 값은 늘 글자 칸에
 * 있고, 고르개와 팔레트는 그 칸에 값을 써넣는 도구다.
 *
 * 고르는 동안 화면의 강조색을 바로 바꾼다. 저장 버튼 자체가 그 색이라, 무엇이
 * 바뀌는지를 설명 없이 보여준다. 저장하기 전까지는 이 화면에서만 그렇다.
 */
(function () {
    "use strict";

    /** 고르개가 다룰 수 있는 값인가. `#RGB` 는 `#RRGGBB` 로 늘려서 넘긴다. */
    function toPickerValue(raw) {
        var value = (raw || "").trim();
        if (/^#[0-9a-fA-F]{3}$/.test(value)) {
            return "#" + value[1] + value[1] + value[2] + value[2] + value[3] + value[3];
        }
        if (/^#[0-9a-fA-F]{6}$/.test(value)) return value;
        // 8자리(투명도 포함)는 앞 여섯 자리만 보여준다. 값 자체는 건드리지 않는다.
        if (/^#[0-9a-fA-F]{8}$/.test(value)) return value.slice(0, 7);
        return null;
    }

    function setUp(field) {
        var target = document.getElementById(field.dataset.colorFor);
        if (!target) return;

        var picker = field.querySelector('input[type="color"]');
        var swatches = Array.prototype.slice.call(field.querySelectorAll("[data-color]"));

        // 비어 있으면 지금 화면에 실제로 쓰이는 색을 고르개의 출발점으로 삼는다.
        // `#3b6fd4` 를 여기 박으면 CSS 의 기본값과 두 곳에서 따로 관리된다.
        function currentAccent() {
            return getComputedStyle(document.documentElement)
                .getPropertyValue("--accent").trim() || "#3b6fd4";
        }

        function preview(value) {
            // 빈 값은 "기본값으로 돌아간다" 이므로 덮어쓴 것을 걷어낸다.
            if (value) {
                document.documentElement.style.setProperty("--accent", value);
            } else {
                document.documentElement.style.removeProperty("--accent");
            }
            markChosen(value);
        }

        function markChosen(value) {
            var normalized = (toPickerValue(value) || "").toLowerCase();
            swatches.forEach(function (swatch) {
                var mine = swatch.dataset.color.toLowerCase();
                swatch.setAttribute("aria-pressed", mine === normalized ? "true" : "false");
            });
        }

        function syncPicker() {
            var value = toPickerValue(target.value);
            if (picker) picker.value = value || toPickerValue(currentAccent()) || "#3b6fd4";
        }

        syncPicker();
        markChosen(target.value);

        if (picker) {
            picker.addEventListener("input", function () {
                target.value = picker.value;
                preview(picker.value);
            });
        }

        // 손으로 적는 쪽도 살아 있어야 한다. 적는 도중에는 아직 색이 아닌 값이
        // 대부분이라, 읽을 수 있게 된 순간에만 반영한다.
        target.addEventListener("input", function () {
            var value = target.value.trim();
            if (value === "" || toPickerValue(value)) {
                syncPicker();
                preview(value);
            }
        });

        swatches.forEach(function (swatch) {
            swatch.addEventListener("click", function () {
                target.value = swatch.dataset.color;
                syncPicker();
                preview(swatch.dataset.color);
            });
        });
    }

    document.querySelectorAll("[data-color-for]").forEach(setUp);
})();
