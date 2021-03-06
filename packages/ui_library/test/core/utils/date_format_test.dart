import 'package:ui_library/core/utils/date_format.dart';
import 'package:given_when_then_unit_test/given_when_then_unit_test.dart';
import 'package:shouldly/shouldly.dart';

void main() {
  given('DateFormatUtils Class - formatDateForNotificationsList function', () {
    then('Year 2000 DateTime should return correctly', () {
      final mockDateTime = DateTime(2000, 01, 01);
      final result =
          DateFormatUtils.formatDateForNotificationsList(mockDateTime);
      result.should.be('January 1, 2000');
    }, and: {
      'Yesterday\'s DateTime should return correctly': () {
        final currentTimeStamp = DateTime.now();
        final mockDateTime = DateTime(currentTimeStamp.year,
            currentTimeStamp.month, currentTimeStamp.day - 1);
        final result =
            DateFormatUtils.formatDateForNotificationsList(mockDateTime);
        result.should.be('Yesterday');
      },
      'Today\'s DateTime should return correctly': () {
        final mockDateTime = DateTime.now();
        final result =
            DateFormatUtils.formatDateForNotificationsList(mockDateTime);
        result.should.be('Today');
      },
    });
  });
  given('DateFormatUtils Class - formatDateTwelveHours function', () {
    then('Year 2000 DateTime should return correctly', () {
      final mockDateTime = DateTime(2000, 01, 01);
      final result = DateFormatUtils.formatDateTwelveHours(mockDateTime);
      result.should.be('12:00AM');
    });
  });
  given('DateFormatUtils Class - formatDateForMessageArrived function', () {
    then('Year 2000 DateTime should return correctly', () {
      final mockDateTime = DateTime(2000, 01, 01);
      final result = DateFormatUtils.formatDateForMessageArrived(mockDateTime);
      result.should.be('01/01/2000');
    }, and: {
      'Two Day\'s before DateTime should return correctly': () {
        final currentTimeStamp = DateTime.now();
        final mockDateTime = DateTime(currentTimeStamp.year,
            currentTimeStamp.month, currentTimeStamp.day - 2);
        final result =
            DateFormatUtils.formatDateForMessageArrived(mockDateTime);
        result.should.be('2d');
      },
      'Yesterday\'s DateTime should return correctly': () {
        final currentTimeStamp = DateTime.now();
        final mockDateTime = DateTime(currentTimeStamp.year,
            currentTimeStamp.month, currentTimeStamp.day - 1);
        final result =
            DateFormatUtils.formatDateForMessageArrived(mockDateTime);
        result.should.be('Yesterday');
      },
      'Today\'s DateTime should return correctly': () {
        final mockDateTime = DateTime.now();
        final result =
            DateFormatUtils.formatDateForMessageArrived(mockDateTime);
        result.should.be('Just Now');
      },
    });
  });
}
