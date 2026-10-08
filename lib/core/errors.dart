sealed class AppException implements Exception {
  const AppException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

base class NetworkException extends AppException {
  const NetworkException(super.message, [super.cause]);
}

final class RequestTimeoutException extends NetworkException {
  const RequestTimeoutException([Object? cause])
    : super('The GetBible request timed out.', cause);
}

/// The bounded public fields of an RFC 9457 problem response. HTML/static-host
/// error bodies are intentionally absent from these typed failures.
final class ApiProblemDetails {
  const ApiProblemDetails({this.code, this.title, this.detail});
  final String? code;
  final String? title;
  final String? detail;
}

base class HttpStatusException extends NetworkException {
  const HttpStatusException({
    required this.statusCode,
    required this.uri,
    required String message,
    this.retryAfter,
    this.problem,
  }) : super(message);

  final int statusCode;
  final Uri uri;
  final Duration? retryAfter;
  final ApiProblemDetails? problem;
}

final class ResourceUnavailableException extends HttpStatusException {
  ResourceUnavailableException(Uri uri, {super.problem})
    : super(
        statusCode: 404,
        uri: uri,
        message:
            problem?.detail ??
            problem?.title ??
            'The requested GetBible resource is unavailable.',
      );
}

final class RateLimitException extends HttpStatusException {
  RateLimitException(Uri uri, {super.retryAfter, super.problem})
    : super(
        statusCode: 429,
        uri: uri,
        message:
            problem?.detail ??
            problem?.title ??
            'GetBible is receiving too many requests. Please retry later.',
      );
}

final class InvalidApiRequestException extends HttpStatusException {
  InvalidApiRequestException({
    required super.statusCode,
    required super.uri,
    super.problem,
  }) : super(
         message:
             problem?.detail ??
             problem?.title ??
             'GetBible could not accept the requested input.',
       );
}

final class RequestCancelledException extends AppException {
  const RequestCancelledException() : super('The request was cancelled.');
}

base class ApiFormatException extends AppException {
  const ApiFormatException(super.message, [super.cause]);
}

final class ResponseTooLargeException extends ApiFormatException {
  const ResponseTooLargeException(this.limitBytes)
    : super('The GetBible response exceeds the permitted size.');

  final int limitBytes;
}

final class StorageException extends AppException {
  const StorageException(super.message, [super.cause]);
}

final class BackupException extends AppException {
  const BackupException(super.message, [super.cause]);
}
