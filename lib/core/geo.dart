/// Угадываем страну (и иногда город) по имени узла из подписки:
/// флаг-эмодзи, двухбуквенный код или название на русском/английском.
class Place {
  const Place(this.code, this.country, this.city);

  final String? code;
  final String? country;
  final String? city;

  static const unknown = Place(null, null, null);

  static Place fromName(String name) {
    String? code = _fromFlag(name);
    String? city;
    final lower = name.toLowerCase();
    for (final entry in _cities.entries) {
      if (lower.contains(entry.key)) {
        city = entry.value.$2;
        code ??= entry.value.$1;
        break;
      }
    }
    if (code == null) {
      for (final c in _countries) {
        if (c.aliases.any(lower.contains)) {
          code = c.code;
          break;
        }
      }
    }
    if (code == null) {
      for (final m in RegExp(r'(?:^|[^A-Za-z])([A-Z]{2})(?=$|[^A-Za-z])').allMatches(name)) {
        final candidate = m.group(1)!;
        if (_byCode.containsKey(candidate)) {
          code = candidate;
          break;
        }
      }
    }
    if (code == null) return unknown;
    return Place(code, _byCode[code]?.ru ?? code, city);
  }

  static String? _fromFlag(String s) {
    final runes = s.runes.toList();
    for (var i = 0; i + 1 < runes.length; i++) {
      final a = runes[i];
      final b = runes[i + 1];
      if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
        final code = String.fromCharCodes([a - 0x1F1E6 + 65, b - 0x1F1E6 + 65]);
        return code == 'UK' ? 'GB' : code;
      }
    }
    return null;
  }

  static String countryName(String code) => _byCode[code]?.ru ?? code;
}

class _Country {
  const _Country(this.code, this.ru, this.aliases);
  final String code;
  final String ru;
  final List<String> aliases;
}

final Map<String, _Country> _byCode = {for (final c in _countries) c.code: c};

const List<_Country> _countries = [
  _Country('NL', 'Нидерланды', ['netherlands', 'нидерланд', 'holland', 'голланд']),
  _Country('DE', 'Германия', ['germany', 'герман', 'deutschland']),
  _Country('FI', 'Финляндия', ['finland', 'финлянд', 'suomi']),
  _Country('SE', 'Швеция', ['sweden', 'швеци']),
  _Country('FR', 'Франция', ['france', 'франци']),
  _Country('GB', 'Великобритания', ['united kingdom', 'britain', 'великобритан', 'англия', 'england']),
  _Country('US', 'США', ['united states', 'america', 'сша', 'usa']),
  _Country('CA', 'Канада', ['canada', 'канад']),
  _Country('PL', 'Польша', ['poland', 'польш']),
  _Country('TR', 'Турция', ['turkey', 'türkiye', 'турци']),
  _Country('KZ', 'Казахстан', ['kazakhstan', 'казахстан']),
  _Country('RU', 'Россия', ['russia', 'росси', 'russian']),
  _Country('UA', 'Украина', ['ukraine', 'украин']),
  _Country('BY', 'Беларусь', ['belarus', 'беларус']),
  _Country('LV', 'Латвия', ['latvia', 'латви']),
  _Country('LT', 'Литва', ['lithuania', 'литв']),
  _Country('EE', 'Эстония', ['estonia', 'эстони']),
  _Country('JP', 'Япония', ['japan', 'япони']),
  _Country('SG', 'Сингапур', ['singapore', 'сингапур']),
  _Country('HK', 'Гонконг', ['hong kong', 'hongkong', 'гонконг']),
  _Country('KR', 'Южная Корея', ['korea', 'корея']),
  _Country('TW', 'Тайвань', ['taiwan', 'тайван']),
  _Country('IN', 'Индия', ['india', 'индия']),
  _Country('AE', 'ОАЭ', ['emirates', 'uae', 'оаэ', 'эмират']),
  _Country('IL', 'Израиль', ['israel', 'израил']),
  _Country('IT', 'Италия', ['italy', 'итали']),
  _Country('ES', 'Испания', ['spain', 'испани']),
  _Country('PT', 'Португалия', ['portugal', 'португал']),
  _Country('CH', 'Швейцария', ['switzerland', 'швейцар']),
  _Country('AT', 'Австрия', ['austria', 'австри']),
  _Country('CZ', 'Чехия', ['czech', 'чехи']),
  _Country('SK', 'Словакия', ['slovakia', 'словаки']),
  _Country('HU', 'Венгрия', ['hungary', 'венгри']),
  _Country('RO', 'Румыния', ['romania', 'румыни']),
  _Country('BG', 'Болгария', ['bulgaria', 'болгари']),
  _Country('RS', 'Сербия', ['serbia', 'серби']),
  _Country('MD', 'Молдова', ['moldova', 'молдов']),
  _Country('GE', 'Грузия', ['georgia', 'грузия']),
  _Country('AM', 'Армения', ['armenia', 'армени']),
  _Country('AZ', 'Азербайджан', ['azerbaijan', 'азербайджан']),
  _Country('UZ', 'Узбекистан', ['uzbekistan', 'узбекистан']),
  _Country('KG', 'Киргизия', ['kyrgyzstan', 'киргиз', 'кыргыз']),
  _Country('TJ', 'Таджикистан', ['tajikistan', 'таджикистан']),
  _Country('MN', 'Монголия', ['mongolia', 'монголи']),
  _Country('CN', 'Китай', ['china', 'китай']),
  _Country('VN', 'Вьетнам', ['vietnam', 'вьетнам']),
  _Country('TH', 'Таиланд', ['thailand', 'таиланд']),
  _Country('MY', 'Малайзия', ['malaysia', 'малайзи']),
  _Country('ID', 'Индонезия', ['indonesia', 'индонези']),
  _Country('PH', 'Филиппины', ['philippines', 'филиппин']),
  _Country('AU', 'Австралия', ['australia', 'австрали']),
  _Country('NZ', 'Новая Зеландия', ['new zealand', 'зеланди']),
  _Country('BR', 'Бразилия', ['brazil', 'бразили']),
  _Country('AR', 'Аргентина', ['argentina', 'аргентин']),
  _Country('CL', 'Чили', ['chile']),
  _Country('MX', 'Мексика', ['mexico', 'мексик']),
  _Country('ZA', 'ЮАР', ['south africa', 'юар']),
  _Country('EG', 'Египет', ['egypt', 'египет']),
  _Country('IR', 'Иран', ['iran', 'иран']),
  _Country('SA', 'Саудовская Аравия', ['saudi', 'саудов']),
  _Country('QA', 'Катар', ['qatar', 'катар']),
  _Country('BE', 'Бельгия', ['belgium', 'бельги']),
  _Country('LU', 'Люксембург', ['luxembourg', 'люксембург']),
  _Country('DK', 'Дания', ['denmark', 'дания']),
  _Country('NO', 'Норвегия', ['norway', 'норвеги']),
  _Country('IS', 'Исландия', ['iceland', 'исланди']),
  _Country('IE', 'Ирландия', ['ireland', 'ирланди']),
  _Country('GR', 'Греция', ['greece', 'греци']),
  _Country('CY', 'Кипр', ['cyprus', 'кипр']),
  _Country('HR', 'Хорватия', ['croatia', 'хорвати']),
  _Country('SI', 'Словения', ['slovenia', 'словени']),
  _Country('AL', 'Албания', ['albania', 'албани']),
  _Country('MK', 'Македония', ['macedonia', 'македони']),
  _Country('BA', 'Босния', ['bosnia', 'босни']),
  _Country('ME', 'Черногория', ['montenegro', 'черногори']),
  _Country('MT', 'Мальта', ['malta', 'мальт']),
  _Country('CO', 'Колумбия', ['colombia', 'колумби']),
  _Country('PE', 'Перу', ['peru']),
];

/// Ключ — фрагмент имени в нижнем регистре, значение — (код страны, город по-русски).
const Map<String, (String, String)> _cities = {
  'amsterdam': ('NL', 'Амстердам'),
  'амстердам': ('NL', 'Амстердам'),
  'rotterdam': ('NL', 'Роттердам'),
  'frankfurt': ('DE', 'Франкфурт'),
  'франкфурт': ('DE', 'Франкфурт'),
  'berlin': ('DE', 'Берлин'),
  'берлин': ('DE', 'Берлин'),
  'munich': ('DE', 'Мюнхен'),
  'nuremberg': ('DE', 'Нюрнберг'),
  'falkenstein': ('DE', 'Фалькенштайн'),
  'helsinki': ('FI', 'Хельсинки'),
  'хельсинки': ('FI', 'Хельсинки'),
  'stockholm': ('SE', 'Стокгольм'),
  'стокгольм': ('SE', 'Стокгольм'),
  'paris': ('FR', 'Париж'),
  'париж': ('FR', 'Париж'),
  'london': ('GB', 'Лондон'),
  'лондон': ('GB', 'Лондон'),
  'warsaw': ('PL', 'Варшава'),
  'варшава': ('PL', 'Варшава'),
  'istanbul': ('TR', 'Стамбул'),
  'стамбул': ('TR', 'Стамбул'),
  'almaty': ('KZ', 'Алматы'),
  'алматы': ('KZ', 'Алматы'),
  'astana': ('KZ', 'Астана'),
  'moscow': ('RU', 'Москва'),
  'москва': ('RU', 'Москва'),
  'saint petersburg': ('RU', 'Санкт-Петербург'),
  'петербург': ('RU', 'Санкт-Петербург'),
  'tokyo': ('JP', 'Токио'),
  'токио': ('JP', 'Токио'),
  'new york': ('US', 'Нью-Йорк'),
  'los angeles': ('US', 'Лос-Анджелес'),
  'dallas': ('US', 'Даллас'),
  'riga': ('LV', 'Рига'),
  'tallinn': ('EE', 'Таллин'),
  'vilnius': ('LT', 'Вильнюс'),
  'vienna': ('AT', 'Вена'),
  'zurich': ('CH', 'Цюрих'),
  'milan': ('IT', 'Милан'),
  'madrid': ('ES', 'Мадрид'),
  'prague': ('CZ', 'Прага'),
  'bucharest': ('RO', 'Бухарест'),
  'sofia': ('BG', 'София'),
  'tbilisi': ('GE', 'Тбилиси'),
  'yerevan': ('AM', 'Ереван'),
  'dubai': ('AE', 'Дубай'),
  'tel aviv': ('IL', 'Тель-Авив'),
  'seoul': ('KR', 'Сеул'),
};
