import 'package:emulator_orchestrator/services/corpus/svd_distiller.dart';
import 'package:test/test.dart';

void main() {
  const svd = '''
<?xml version="1.0"?>
<device><name>STM32WB05</name><peripherals>
  <peripheral>
    <name>USART1</name>
    <baseAddress>0x40013800</baseAddress>
    <registers>
      <register>
        <name>CR1</name><addressOffset>0x00</addressOffset>
        <resetValue>0x0000</resetValue><access>read-write</access>
        <fields>
          <field><name>UE</name><bitOffset>0</bitOffset><bitWidth>1</bitWidth></field>
          <field><name>TE</name><bitOffset>3</bitOffset><bitWidth>1</bitWidth></field>
        </fields>
      </register>
    </registers>
  </peripheral>
  <peripheral derivedFrom="USART1">
    <name>USART2</name>
    <baseAddress>0x40004400</baseAddress>
  </peripheral>
</peripherals></device>
''';

  test('one chunk per peripheral with base, offsets, fields', () {
    final chunks = const SvdDistiller().distill(svd, part: 'STM32WB05');
    expect(chunks.map((c) => c.name), ['USART1', 'USART2']);

    final u1 = chunks.first.text;
    expect(u1, contains('Peripheral: USART1'));
    expect(u1, contains('@ 0x40013800'));
    expect(u1, contains('CR1  offset 0x00'));
    expect(u1, contains('reset 0x0000'));
    expect(u1, contains('UE[0]'));
    expect(u1, contains('TE[3]'));
  });

  test('derivedFrom peripheral inherits the register map', () {
    final u2 = const SvdDistiller()
        .distill(svd, part: 'STM32WB05')
        .firstWhere((c) => c.name == 'USART2')
        .text;
    expect(u2, contains('derived from USART1'));
    expect(u2, contains('@ 0x40004400'));
    expect(u2, contains('CR1  offset 0x00'), reason: 'inherited register');
  });
}
