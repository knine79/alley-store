import Vapor

/// 그린 화면을 그대로 실어 보낸다.
///
/// 폼을 POST 로 받아 그 자리에서 다시 그리는 화면들이 쓴다. 리다이렉트하지 않는
/// 이유는 화면마다 다르지만(토큰 원문은 그 응답에만 있고, 적어 넣은 값은 되살려야
/// 한다) 만드는 방법은 같다.
///
/// 네 컨트롤러가 같은 세 줄을 따로 갖고 있었다. 헤더 하나를 더해야 할 때 네 곳을
/// 찾아다니게 된다.
func htmlResponse(_ view: View, status: HTTPStatus) -> Response {
    let response = Response(status: status)
    response.headers.contentType = .html
    response.body = .init(buffer: view.data)
    return response
}
