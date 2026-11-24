import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/phone/device_name.dart';

void main() {
  test('manufacturer and model, unless the model says it already', () {
    expect(
      phoneNameFor(manufacturer: 'samsung', model: 'SM-S918B'),
      'Samsung SM-S918B',
    );
    expect(
      phoneNameFor(manufacturer: 'Google', model: 'Pixel 9 Pro XL'),
      'Pixel 9 Pro XL',
    );
    expect(
      phoneNameFor(manufacturer: 'OnePlus', model: 'OnePlus 12'),
      'OnePlus 12',
    );
    expect(phoneNameFor(manufacturer: 'unknown', model: 'X1'), 'X1');
    expect(phoneNameFor(manufacturer: 'Sony', model: '  '), 'Phone');
    expect(phoneNameFor(), 'Phone');
  });
}
