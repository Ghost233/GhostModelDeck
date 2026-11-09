import 'dart:convert';
import 'dart:io';

Future<({int status, String? mime, String body})> postNativeText(
  Uri base,
  String path,
  Map<String, Object?> body,
) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(base.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer client-key');
    request.headers.set('x-api-key', 'client-key');
    request.headers.set('anthropic-version', '2023-06-01');
    request.write(jsonEncode(body));
    final response = await request.close();
    return (
      status: response.statusCode,
      mime: response.headers.contentType?.mimeType,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close(force: true);
  }
}
