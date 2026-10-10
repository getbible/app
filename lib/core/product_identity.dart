/// Product branding and public destinations shared by the native reader.
///
/// Documentation destinations are separate from the service API endpoints.
abstract final class ProductIdentity {
  static const String name = 'getBible';

  static final Uri websiteUri = Uri.parse('https://app.getbible.life');
  static final Uri documentationUri = Uri.parse('https://getbible.net');
  static final Uri bibleApiDocumentationUri = Uri.parse(
    'https://getbible.net/api/bible/',
  );
}
