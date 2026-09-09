/*
 * 올릴 zip 안의 `Info.plist` 를 브라우저에서 읽는다.
 *
 * 사람이 손으로 옮겨 적던 값을 번들에서 그대로 가져온다. 번들 ID 는 서명 전에
 * 대조하므로(ADR-0029) 틀리면 어차피 막히는데, 막히는 것을 올린 다음에 아는 것보다
 * 애초에 안 틀리는 것이 낫다.
 *
 * 빌드 스텝 없이 브라우저가 그대로 읽는다. 외부 라이브러리를 안 쓰는 것은 취향이
 * 아니라 제약이다. CSP 가 `script-src 'self'` 라 CDN 에서 아무것도 못 받는다.
 *
 * 읽지 못하면 던진다. 부르는 쪽은 입력칸을 비워두고 사람이 적게 하면 된다.
 * **자동 채우기가 실패하는 것은 업로드가 실패하는 것이 아니다.**
 */
(function () {
    "use strict";

    /** 우리가 쓰는 키만 꺼낸다. 나머지는 볼 이유가 없다. */
    var KEYS = [
        "CFBundleIdentifier",
        "CFBundleDisplayName",
        "CFBundleName",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "LSMinimumSystemVersion"
    ];

    /*
     * zip 에서 최상위 `.app` 의 Info.plist 를 찾아 읽는다.
     *
     * 최상위만 본다. 번들 안의 헬퍼 앱에도 Info.plist 가 있고, 그것을 집으면 엉뚱한
     * 앱의 값을 채운다. 서명 대상을 고를 때 같은 함정을 이미 한 번 만났다.
     */
    async function read(file) {
        var directory = await readCentralDirectory(file);
        var entry = pickInfoPlist(directory);
        if (!entry) {
            throw new Error("zip 안에서 최상위 .app 의 Info.plist 를 찾지 못했습니다.");
        }

        var bytes = await inflateEntry(file, entry);
        var plist = parsePlist(bytes);

        return {
            bundleID: plist.CFBundleIdentifier || null,
            // 표시 이름이 있으면 그것이 사람이 보는 이름이다.
            name: plist.CFBundleDisplayName || plist.CFBundleName || null,
            shortVersion: plist.CFBundleShortVersionString || null,
            buildNumber: plist.CFBundleVersion || null,
            minimumOSVersion: plist.LSMinimumSystemVersion || null
        };
    }

    // MARK: - zip

    /*
     * 중앙 디렉터리를 읽는다.
     *
     * 앞에서부터 훑지 않는다. 수백 MB 짜리 zip 을 통째로 메모리에 올리지 않으려면
     * 끝에 있는 목록만 읽어야 한다. zip 은 그러라고 만들어진 형식이다.
     */
    async function readCentralDirectory(file) {
        // EOCD 는 가변 길이 주석을 달 수 있고 주석은 최대 65535 바이트다.
        var tailSize = Math.min(file.size, 65535 + 22);
        var tail = new DataView(await file.slice(file.size - tailSize).arrayBuffer());

        var eocd = -1;
        for (var i = tail.byteLength - 22; i >= 0; i--) {
            if (tail.getUint32(i, true) === 0x06054b50) {
                eocd = i;
                break;
            }
        }
        if (eocd < 0) {
            // dmg 는 흔한 실수가 아니라 정상적인 선택지다. 서버는 받아준다.
            // 다만 브라우저가 APFS·HFS+ 디스크 이미지를 열 방법이 없어서 자동
            // 채우기만 안 된다. "형식이 아니다" 로 끝내면 못 올리는 줄 안다.
            if (await looksLikeDiskImage(file)) {
                throw new Error(
                    "dmg 는 브라우저가 열 수 없어 값을 읽지 못합니다. " +
                    "올리는 데는 문제 없으니 아래 칸만 직접 채우세요."
                );
            }
            throw new Error("zip 형식이 아닙니다.");
        }

        var count = tail.getUint16(eocd + 10, true);
        var size = tail.getUint32(eocd + 12, true);
        var offset = tail.getUint32(eocd + 16, true);

        // 0xFFFFFFFF 는 "이 값은 zip64 확장에 있다" 는 표시다. 4GB 를 넘거나 항목이
        // 65535 개를 넘으면 그렇게 된다. 그 형식까지 읽지는 않는다. 앱 하나가 그
        // 크기라면 자동 채우기가 아니라 다른 것을 걱정해야 한다.
        if (offset === 0xffffffff || size === 0xffffffff || count === 0xffff) {
            throw new Error("zip64 형식은 읽지 못합니다. 값을 직접 입력하세요.");
        }

        var view = new DataView(await file.slice(offset, offset + size).arrayBuffer());
        var entries = [];
        var at = 0;
        for (var n = 0; n < count && at + 46 <= view.byteLength; n++) {
            if (view.getUint32(at, true) !== 0x02014b50) break;

            var nameLength = view.getUint16(at + 28, true);
            var extraLength = view.getUint16(at + 30, true);
            var commentLength = view.getUint16(at + 32, true);

            entries.push({
                name: decodeName(view, at + 46, nameLength),
                method: view.getUint16(at + 10, true),
                compressedSize: view.getUint32(at + 20, true),
                localHeaderOffset: view.getUint32(at + 42, true)
            });

            at += 46 + nameLength + extraLength + commentLength;
        }
        return entries;
    }

    /*
     * UDIF(dmg) 인가. 파일 **끝** 512바이트가 트레일러이고 그 앞 4바이트가 `koly` 다.
     *
     * 워커 쪽 `ArtifactFormat` 과 같은 판정이다. 두 곳에 있는 이유는 쓰임이 달라서다.
     * 워커는 어떻게 풀지 정하려고 보고, 여기서는 "왜 자동 채우기가 안 되는지" 를
     * 정확히 말하려고 본다.
     */
    async function looksLikeDiskImage(file) {
        if (file.size < 512) return false;
        var trailer = new Uint8Array(await file.slice(file.size - 512, file.size - 508).arrayBuffer());
        return new TextDecoder("ascii").decode(trailer) === "koly";
    }

    /*
     * 이름이 `<무엇>.app/Contents/Info.plist` 인 항목. 딱 한 겹만 허용한다.
     *
     * macOS 가 zip 을 만들 때 끼워 넣는 `__MACOSX` 는 걸러낸다. 그 안에도 같은
     * 경로 모양의 항목이 들어 있는데 내용은 리소스 포크다.
     */
    function pickInfoPlist(entries) {
        for (var i = 0; i < entries.length; i++) {
            var name = entries[i].name;
            if (name.indexOf("__MACOSX") === 0) continue;
            if (/^[^/]+\.app\/Contents\/Info\.plist$/.test(name)) return entries[i];
        }
        return null;
    }

    /*
     * 항목 하나를 꺼내 압축을 푼다.
     *
     * 중앙 디렉터리의 이름 길이를 믿지 않고 로컬 헤더에서 다시 읽는다. 두 값이
     * 어긋난 zip 이 실제로 있고, 어긋나면 데이터 시작 위치를 잘못 짚는다.
     */
    async function inflateEntry(file, entry) {
        var header = new DataView(
            await file.slice(entry.localHeaderOffset, entry.localHeaderOffset + 30).arrayBuffer()
        );
        if (header.getUint32(0, true) !== 0x04034b50) {
            throw new Error("zip 항목의 헤더가 깨졌습니다.");
        }
        var start = entry.localHeaderOffset + 30
            + header.getUint16(26, true)
            + header.getUint16(28, true);

        var blob = file.slice(start, start + entry.compressedSize);
        if (entry.method === 0) return new Uint8Array(await blob.arrayBuffer());
        if (entry.method !== 8) {
            throw new Error("압축 방식 " + entry.method + " 은 읽지 못합니다.");
        }

        // zip 의 deflate 는 zlib 헤더가 없는 raw deflate 다.
        var stream = blob.stream().pipeThrough(new DecompressionStream("deflate-raw"));
        return new Uint8Array(await new Response(stream).arrayBuffer());
    }

    /** zip 항목 이름. UTF-8 플래그가 없는 옛 zip 도 UTF-8 로 읽어 크게 틀리지 않는다. */
    function decodeName(view, at, length) {
        return new TextDecoder("utf-8").decode(
            new Uint8Array(view.buffer, view.byteOffset + at, length)
        );
    }

    // MARK: - plist

    /*
     * XML 과 바이너리 양쪽을 읽는다.
     *
     * **둘 다 필요하다.** 이 머신의 `/Applications` 를 세어보니 50개 중 10개가
     * 바이너리였다. Xcode 로 만든 앱이 그렇고, Electron 앱은 XML 이다. 한쪽만 읽으면
     * 자동 채우기가 앱의 종류에 따라 되기도 하고 안 되기도 한다.
     */
    function parsePlist(bytes) {
        var magic = new TextDecoder("ascii").decode(bytes.subarray(0, 6));
        return magic === "bplist" ? parseBinaryPlist(bytes) : parseXMLPlist(bytes);
    }

    function parseXMLPlist(bytes) {
        var text = new TextDecoder("utf-8").decode(bytes);
        var document = new DOMParser().parseFromString(text, "application/xml");
        if (document.querySelector("parsererror")) {
            throw new Error("Info.plist 를 해석하지 못했습니다.");
        }

        var dict = document.querySelector("plist > dict");
        if (!dict) throw new Error("Info.plist 에 최상위 dict 가 없습니다.");

        // `key` 다음 형제가 그 값이다. 중첩 dict 안의 key 는 건너뛴다.
        var result = {};
        var nodes = dict.children;
        for (var i = 0; i < nodes.length; i++) {
            if (nodes[i].tagName !== "key") continue;
            var key = nodes[i].textContent.trim();
            var value = nodes[i + 1];
            if (!value || KEYS.indexOf(key) < 0) continue;
            if (value.tagName === "string" || value.tagName === "integer"
                || value.tagName === "real") {
                result[key] = value.textContent.trim();
            }
        }
        return result;
    }

    /*
     * 바이너리 plist v0 에서 최상위 dict 의 문자열 값만 꺼낸다.
     *
     * 전체 형식을 구현하지 않는다. 우리가 읽는 여섯 키는 모두 문자열이고, 최상위
     * dict 바로 아래에 있다. 배열·중첩 dict·날짜·데이터는 만나면 건너뛴다.
     * 형식 문서는 CoreFoundation 의 `CFBinaryPList.c` 다.
     */
    function parseBinaryPlist(bytes) {
        var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        if (bytes.byteLength < 40) throw new Error("Info.plist 가 너무 짧습니다.");

        // 트레일러는 마지막 32 바이트다.
        var trailer = bytes.byteLength - 32;
        var offsetSize = view.getUint8(trailer + 6);
        var refSize = view.getUint8(trailer + 7);
        var objectCount = readBig(view, trailer + 8);
        var rootRef = readBig(view, trailer + 16);
        var tableOffset = readBig(view, trailer + 24);

        var offsets = [];
        for (var i = 0; i < objectCount; i++) {
            offsets.push(readSized(view, tableOffset + i * offsetSize, offsetSize));
        }

        var root = readObject(rootRef);
        if (!root || root.type !== "dict") {
            throw new Error("Info.plist 의 최상위가 dict 가 아닙니다.");
        }

        var result = {};
        for (var n = 0; n < root.keys.length; n++) {
            var key = readObject(root.keys[n]);
            if (!key || key.type !== "string" || KEYS.indexOf(key.value) < 0) continue;
            var value = readObject(root.values[n]);
            if (value && (value.type === "string" || value.type === "number")) {
                result[key.value] = String(value.value);
            }
        }
        return result;

        function readObject(ref) {
            if (ref >= offsets.length) return null;
            var at = offsets[ref];
            var marker = view.getUint8(at);
            var kind = marker >> 4;
            var count = marker & 0x0f;

            if (kind === 0x5 || kind === 0x6 || kind === 0xd || kind === 0xa) {
                // 길이가 15 이상이면 다음 바이트들에 실제 길이가 있다.
                var body = at + 1;
                if (count === 0x0f) {
                    var lengthMarker = view.getUint8(body);
                    var lengthBytes = 1 << (lengthMarker & 0x0f);
                    count = readSized(view, body + 1, lengthBytes);
                    body += 1 + lengthBytes;
                }
                if (kind === 0x5) {
                    return {
                        type: "string",
                        value: new TextDecoder("ascii").decode(
                            new Uint8Array(view.buffer, view.byteOffset + body, count)
                        )
                    };
                }
                if (kind === 0x6) {
                    // UTF-16 빅엔디언. 한글 앱 이름이 여기로 온다.
                    return {
                        type: "string",
                        value: new TextDecoder("utf-16be").decode(
                            new Uint8Array(view.buffer, view.byteOffset + body, count * 2)
                        )
                    };
                }
                if (kind === 0xd) {
                    var keys = [];
                    var values = [];
                    for (var k = 0; k < count; k++) {
                        keys.push(readSized(view, body + k * refSize, refSize));
                        values.push(
                            readSized(view, body + (count + k) * refSize, refSize)
                        );
                    }
                    return { type: "dict", keys: keys, values: values };
                }
                return { type: "array" };
            }

            if (kind === 0x1) {
                // 정수. 길이는 2^count 바이트다.
                return { type: "number", value: readSized(view, at + 1, 1 << count) };
            }
            if (kind === 0x2) {
                var size = 1 << count;
                if (size === 4) return { type: "number", value: view.getFloat32(at + 1) };
                if (size === 8) return { type: "number", value: view.getFloat64(at + 1) };
            }
            return null;
        }
    }

    /** 트레일러의 8바이트 값. 상위 4바이트는 실제 파일에서 0 이다. */
    function readBig(view, at) {
        return view.getUint32(at, false) * 0x100000000 + view.getUint32(at + 4, false);
    }

    /** 빅엔디언 정수 하나. plist 의 길이·오프셋은 모두 이 꼴이다. */
    function readSized(view, at, size) {
        var value = 0;
        for (var i = 0; i < size; i++) {
            value = value * 256 + view.getUint8(at + i);
        }
        return value;
    }

    window.AlleyBundleInfo = { read: read };
})();
