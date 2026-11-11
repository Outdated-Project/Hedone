//! NextJson at the HTTP boundary, retaining Axum's configured body limit.
use axum::{
    body::Bytes,
    extract::{FromRequest, Request},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use nextjson::{NsonDeserialize, NsonSerialize};

pub(crate) struct Json<T>(pub T);
impl<S, T> FromRequest<S> for Json<T>
where
    S: Send + Sync,
    T: for<'de> NsonDeserialize<'de>,
{
    type Rejection = Response;
    async fn from_request(request: Request, state: &S) -> Result<Self, Self::Rejection> {
        let content = request
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if content.split(';').next().unwrap_or("").trim() != "application/json" {
            return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response());
        }
        let bytes = Bytes::from_request(request, state)
            .await
            .map_err(IntoResponse::into_response)?;
        nextjson::from_slice(&bytes)
            .map(Self)
            .map_err(|_| StatusCode::BAD_REQUEST.into_response())
    }
}
impl<T: NsonSerialize> IntoResponse for Json<T> {
    fn into_response(self) -> Response {
        match nextjson::to_vec(&self.0) {
            Ok(bytes) => ([("content-type", "application/json")], bytes).into_response(),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        }
    }
}
