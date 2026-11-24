/// The name a new phone pairs with, from what Android reports.
///
/// "Samsung SM-S918B" (manufacturer and model), but just "Pixel 9 Pro XL"
/// when the model already names its maker. Empty input gives "Phone".
String phoneNameFor({String? manufacturer, String? model}) {
  final m = (model ?? '').trim();
  if (m.isEmpty) return 'Phone';
  var maker = (manufacturer ?? '').trim();
  if (maker.isEmpty || maker.toLowerCase() == 'unknown') return m;
  final lower = m.toLowerCase();
  // "Pixel 9" and "Galaxy S24" already say who made them.
  if (lower.contains(maker.toLowerCase()) || lower.startsWith('pixel')) {
    return m;
  }
  maker = maker[0].toUpperCase() + maker.substring(1);
  return '$maker $m';
}
