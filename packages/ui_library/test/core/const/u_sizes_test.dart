import 'package:ui_library/core/const/const_export.dart';
import 'package:given_when_then_unit_test/given_when_then_unit_test.dart';
import 'package:shouldly/shouldly.dart';

void main() {
  given('USizes Class - Size\'s value', () {
    const _iconSize = 24.0;
    const _iconSizeSmall = 20.0;
    const _iconAddPictureProfileButtonSize = 14.4;
    const _iconSizeMicro = 16.0;
    const _buttonSize = 56.0;
    const _buttonSizeSmall = 40.0;
    const _textH1TopMenuBarTitleSize = 18.0;
    const _textH2SecondaryHeaderSize = 14.0;
    const _textH3TertiaryHeaderSize = 13.0;
    const _textH4FourthHeaderSize = 13.0;
    const _textH5FifthHeaderSize = 12.0;
    const _textB1BodySize = 12.0;
    const _textB2MediumSize = 12.0;
    const _textB3BoldSize = 12.0;
    const _textB4ItalicsSize = 12.0;
    const _textM1MicroSize = 10.0;
    const _textBUT1ButtonSize = 12.0;
    const _textBUT2SecondaryButtonSize = 12.0;
    const _unreadMessagesIndicatorSize = 20.0;
    const _userProfileTopMenuBarSize = 30.0;
    const _userProfileNormalSize = 40.0;
    const _userProfileLargeSize = 56.0;
    const _userProfileStatusSmallSize = 8.0;
    const _userProfileStatusNormalSize = 12.0;
    const _userProfileNormalMaxUsernameTextSize = 72.0;
    const _userProfileMessagesUnreadsMaxMessagesSize = 42.0;
    const _avatarProfileNormalSize = 40.0;
    const _avatarProfileLargeSize = 56.0;
    const _unreadMessagesLessThanTenWidthSize = 20.0;
    const _unreadMessagesLessThanHundredWidthSize = 27.0;
    const _unreadMessagesLessThanThousandWidthSize = 35.0;
    const _unreadMessagesGreaterThanOrEqualToThousandWidthSize = 42.0;
    const _uUnreadMessagesUserProfileCardDateTextWidthSize = 62.0;
    const _unreadMessagesUserProfileCardWidthSize = 58.0;
    const _uNavDrawerUserProfileCardHeightSize = 88.0;
    const _uNotificationDateTextWidthSize = 62.0;
    const _uNotificationStandardHeightSize = 40.0;
    const _uNotificationServerMessageHeightSize = 58.0;
    const _uNotificationFriendRequestUpsideHeightSize = 59.0;
    const _uNotificationFriendRequesBottomSideHeightSize = 48.0;
    const _uNotificationLinkHeightSize = 140.0;
    const _uNotificationLinkBottomSideHeightSize = 92.0;
    const _uNotificationLinkUpsideHeightSize = 40.0;
    const _messageOnUnreadMessagesUserProfileCardWidthSize = 248;
    const _messageOnUserProfileCardWidthSize = 270;
    const _pinButtonSize = 50.0;
    const _pinDotSize = 16;
    const _recoverySeedBoxWidthSize = 160.0;
    const _recoverySeedBoxHeightSize = 40.0;
    const _recoverySeedBoxNumberBoxWidthSize = 14.0;
    const _recoverySeedBoxNumberBoxHeightSize = 15.0;
    const _switcherTotalHeight = 20.0;
    const _switcherTotalWidth = 36.0;
    const _switcherTrackHeight = 16.0;
    const _dropDownMenuButtonHeight = 40;
    const _dropDownMenuItemHeight = 48;
    const _barAboveBottomSheetHeightSize = 2.0;
    const _barAboveBottomSheetWidthSize = 72.0;
    const _barAboveBottomSheetBorderRadius = 8.0;
    const _bottomSheetTemplateBorderRadius = 20.0;
    const _userPictureChangeSize = 100.0;
    const _userPictureChangeAddButtonSize = 24.0;
    const _loadingIndicatorHeight = 6.0;
    const _folderButtonHeight = 168;
    const _folderButtonWidth = 160;
    const _imageButtonHeight = 168;
    const _imageButtonWidth = 160;
    const _singleLineHeight = 56;
    const _multiLinesHeight = 87;
    const _singleLineMaxLines = 1;
    const _multiLinesMaxLines = 3;
    const _idBoxHeight = 56;

    then('iconSize should return correct value',
        () => USizes.iconSize.should.be(_iconSize),
        and: {
          'iconSizeSmall should return correct value': () =>
              USizes.iconSizeSmall.should.be(_iconSizeSmall),
          'iconAddPictureProfileButtonSize should return correct value': () =>
              USizes.iconAddPictureProfileButtonSize.should
                  .be(_iconAddPictureProfileButtonSize),
          'iconSizeMicro should return correct value': () =>
              USizes.iconSizeMicro.should.be(_iconSizeMicro),
          'buttonSize should return correct value': () =>
              USizes.buttonSize.should.be(_buttonSize),
          'buttonSizeSmall should return correct value': () =>
              USizes.buttonSizeSmall.should.be(_buttonSizeSmall),
          'textH1TopMenuBarTitleSize should return correct value': () => USizes
              .textH1TopMenuBarTitleSize.should
              .be(_textH1TopMenuBarTitleSize),
          'textH2SecondaryHeaderSize should return correct value': () => USizes
              .textH2SecondaryHeaderSize.should
              .be(_textH2SecondaryHeaderSize),
          'textH3TertiaryHeaderSize should return correct value': () => USizes
              .textH3TertiaryHeaderSize.should
              .be(_textH3TertiaryHeaderSize),
          'textH4FourthHeaderSize should return correct value': () =>
              USizes.textH4FourthHeaderSize.should.be(_textH4FourthHeaderSize),
          'textH5FifthHeaderSize should return correct value': () =>
              USizes.textH5FifthHeaderSize.should.be(_textH5FifthHeaderSize),
          'textB1BodySize should return correct value': () =>
              USizes.textB1BodySize.should.be(_textB1BodySize),
          'textB2MediumSize should return correct value': () =>
              USizes.textB2MediumSize.should.be(_textB2MediumSize),
          'textB3BoldSize should return correct value': () =>
              USizes.textB3BoldSize.should.be(_textB3BoldSize),
          'textB4ItalicsSize should return correct value': () =>
              USizes.textB4ItalicsSize.should.be(_textB4ItalicsSize),
          'textM1MicroSize should return correct value': () =>
              USizes.textM1MicroSize.should.be(_textM1MicroSize),
          'textBUT1ButtonSize should return correct value': () =>
              USizes.textBUT1ButtonSize.should.be(_textBUT1ButtonSize),
          'textBUT2SecondaryButtonSize should return correct value': () =>
              USizes.textBUT2SecondaryButtonSize.should
                  .be(_textBUT2SecondaryButtonSize),
          'unreadMessagesIndicatorSize should return correct value': () =>
              USizes.unreadMessagesIndicatorSize.should
                  .be(_unreadMessagesIndicatorSize),
          'userProfileTopMenuBarSize should return correct value': () => USizes
              .userProfileTopMenuBarSize.should
              .be(_userProfileTopMenuBarSize),
          'userProfileNormalSize should return correct value': () =>
              USizes.userProfileNormalSize.should.be(_userProfileNormalSize),
          'userProfileLargeSize should return correct value': () =>
              USizes.userProfileLargeSize.should.be(_userProfileLargeSize),
          'userProfileStatusSmallSize should return correct value': () => USizes
              .userProfileStatusSmallSize.should
              .be(_userProfileStatusSmallSize),
          'userProfileStatusNormalSize should return correct value': () =>
              USizes.userProfileStatusNormalSize.should
                  .be(_userProfileStatusNormalSize),
          'userProfileNormalMaxUsernameTextSize should return correct value':
              () => USizes.userProfileNormalMaxUsernameTextSize.should
                  .be(_userProfileNormalMaxUsernameTextSize),
          'userProfileMessagesUnreadsMaxMessagesSize should return correct value':
              () => USizes.userProfileMessagesUnreadsMaxMessagesSize.should
                  .be(_userProfileMessagesUnreadsMaxMessagesSize),
          'avatarProfileNormalSize should return correct value': () => USizes
              .avatarProfileNormalSize.should
              .be(_avatarProfileNormalSize),
          'avatarProfileLargeSize should return correct value': () =>
              USizes.avatarProfileLargeSize.should.be(_avatarProfileLargeSize),
          'unreadMessagesLessThanTenWidthSize should return correct value':
              () => USizes.unreadMessagesLessThanTenWidthSize.should
                  .be(_unreadMessagesLessThanTenWidthSize),
          'unreadMessagesLessThanHundredWidthSize should return correct value':
              () => USizes.unreadMessagesLessThanHundredWidthSize.should
                  .be(_unreadMessagesLessThanHundredWidthSize),
          'unreadMessagesLessThanThousandWidthSize should return correct value':
              () => USizes.unreadMessagesLessThanThousandWidthSize.should
                  .be(_unreadMessagesLessThanThousandWidthSize),
          'unreadMessagesGreaterThanOrEqualToThousandWidthSize should return correct value':
              () => USizes
                  .unreadMessagesGreaterThanOrEqualToThousandWidthSize.should
                  .be(_unreadMessagesGreaterThanOrEqualToThousandWidthSize),
          'uUnreadMessagesUserProfileCardDateTextWidthSize should return correct value':
              () => USizes
                  .uUnreadMessagesUserProfileCardDateTextWidthSize.should
                  .be(_uUnreadMessagesUserProfileCardDateTextWidthSize),
          'unreadMessagesUserProfileCardWidthSize should return correct value':
              () => USizes.unreadMessagesUserProfileCardWidthSize.should
                  .be(_unreadMessagesUserProfileCardWidthSize),
          'uNavDrawerUserProfileCardHeightSize should return correct value':
              () => USizes.uNavDrawerUserProfileCardHeightSize.should
                  .be(_uNavDrawerUserProfileCardHeightSize),
          'uNotificationDateTextWidthSize should return correct value': () =>
              USizes.uNotificationDateTextWidthSize.should
                  .be(_uNotificationDateTextWidthSize),
          'uNotificationStandardHeightSize should return correct value': () =>
              USizes.uNotificationStandardHeightSize.should
                  .be(_uNotificationStandardHeightSize),
          'uNotificationServerMessageHeightSize should return correct value':
              () => USizes.uNotificationServerMessageHeightSize.should
                  .be(_uNotificationServerMessageHeightSize),
          'uNotificationFriendRequestUpsideHeightSize should return correct value':
              () => USizes.uNotificationFriendRequestUpsideHeightSize.should
                  .be(_uNotificationFriendRequestUpsideHeightSize),
          'uNotificationFriendRequesBottomSideHeightSize should return correct value':
              () => USizes.uNotificationFriendRequesBottomSideHeightSize.should
                  .be(_uNotificationFriendRequesBottomSideHeightSize),
          'uNotificationLinkHeightSize should return correct value': () =>
              USizes.uNotificationLinkHeightSize.should
                  .be(_uNotificationLinkHeightSize),
          'uNotificationLinkBottomSideHeightSize should return correct value':
              () => USizes.uNotificationLinkBottomSideHeightSize.should
                  .be(_uNotificationLinkBottomSideHeightSize),
          'uNotificationLinkUpsideHeightSize should return correct value': () =>
              USizes.uNotificationLinkUpsideHeightSize.should
                  .be(_uNotificationLinkUpsideHeightSize),
          'messageOnUnreadMessagesUserProfileCardWidthSize should return correct value':
              () => USizes
                  .messageOnUnreadMessagesUserProfileCardWidthSize.should
                  .be(_messageOnUnreadMessagesUserProfileCardWidthSize),
          'messageOnUserProfileCardWidthSize should return correct value': () =>
              USizes.messageOnUserProfileCardWidthSize.should
                  .be(_messageOnUserProfileCardWidthSize),
          'pinButtonSize should return correct value': () =>
              USizes.pinButtonSize.should.be(_pinButtonSize),
          'pinDotSize should return correct value': () =>
              USizes.pinDotSize.should.be(_pinDotSize),
          'recoverySeedBoxWidthSize should return correct value': () => USizes
              .recoverySeedBoxWidthSize.should
              .be(_recoverySeedBoxWidthSize),
          'recoverySeedBoxHeightSize should return correct value': () => USizes
              .recoverySeedBoxHeightSize.should
              .be(_recoverySeedBoxHeightSize),
          'recoverySeedBoxNumberBoxWidthSize should return correct value': () =>
              USizes.recoverySeedBoxNumberBoxWidthSize.should
                  .be(_recoverySeedBoxNumberBoxWidthSize),
          'recoverySeedBoxNumberBoxHeightSize should return correct value':
              () => USizes.recoverySeedBoxNumberBoxHeightSize.should
                  .be(_recoverySeedBoxNumberBoxHeightSize),
          'switcherTotalHeight should return correct value': () =>
              USizes.switcherTotalHeight.should.be(_switcherTotalHeight),
          'switcherTotalWidth should return correct value': () =>
              USizes.switcherTotalWidth.should.be(_switcherTotalWidth),
          'switcherTrackHeight should return correct value': () =>
              USizes.switcherTrackHeight.should.be(_switcherTrackHeight),
          'dropDownMenuButtonHeight should return correct value': () => USizes
              .dropDownMenuButtonHeight.should
              .be(_dropDownMenuButtonHeight),
          'dropDownMenuItemHeight should return correct value': () =>
              USizes.dropDownMenuItemHeight.should.be(_dropDownMenuItemHeight),
          'barAboveBottomSheetHeightSize should return correct value': () =>
              USizes.barAboveBottomSheetHeightSize.should
                  .be(_barAboveBottomSheetHeightSize),
          'barAboveBottomSheetWidthSize should return correct value': () =>
              USizes.barAboveBottomSheetWidthSize.should
                  .be(_barAboveBottomSheetWidthSize),
          'barAboveBottomSheetBorderRadius should return correct value': () =>
              USizes.barAboveBottomSheetBorderRadius.should
                  .be(_barAboveBottomSheetBorderRadius),
          'bottomSheetTemplateBorderRadius should return correct value': () =>
              USizes.bottomSheetTemplateBorderRadius.should
                  .be(_bottomSheetTemplateBorderRadius),
          'userPictureChangeSize should return correct value': () =>
              USizes.userPictureChangeSize.should.be(_userPictureChangeSize),
          'userPictureChangeAddButtonSize should return correct value': () =>
              USizes.userPictureChangeAddButtonSize.should
                  .be(_userPictureChangeAddButtonSize),
          'loadingIndicatorHeight should return correct value': () =>
              USizes.loadingIndicatorHeight.should.be(_loadingIndicatorHeight),
          'folderButtonHeight should return correct value': () =>
              USizes.folderButtonHeight.should.be(_folderButtonHeight),
          'folderButtonWidth should return correct value': () =>
              USizes.folderButtonWidth.should.be(_folderButtonWidth),
          'imageButtonHeight should return correct value': () =>
              USizes.imageButtonHeight.should.be(_imageButtonHeight),
          'imageButtonWidth should return correct value': () =>
              USizes.imageButtonWidth.should.be(_imageButtonWidth),
          'singleLineHeight should return correct value': () =>
              USizes.singleLineHeight.should.be(_singleLineHeight),
          'multiLinesHeight should return correct value': () =>
              USizes.multiLinesHeight.should.be(_multiLinesHeight),
          'singleLineMaxLines should return correct value': () =>
              USizes.singleLineMaxLines.should.be(_singleLineMaxLines),
          'multiLinesMaxLines should return correct value': () =>
              USizes.multiLinesMaxLines.should.be(_multiLinesMaxLines),
          'idBoxHeight should return correct value': () =>
              USizes.idBoxHeight.should.be(_idBoxHeight),
        });
  });
}
