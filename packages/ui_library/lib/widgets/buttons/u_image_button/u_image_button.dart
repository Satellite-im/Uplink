import 'package:flutter/material.dart';
import 'package:ui_library/ui_library_export.dart';

class UImageButton extends StatefulWidget {
  ///Used in file session to preview image
  ///
  ///When [isDeleting] set to ture, it will show a checkbox
  ///
  ///You can use [isSelected] in UImageButtonState to get it is checked or not
  ///
  ///All the boolean properties are false by default
  const UImageButton({
    Key? key,
    required this.uImage,
    this.isLinked,
    this.isFavored,
    this.isDeleting,
  }) : super(key: key);

  final UImage uImage;
  final bool? isLinked;
  final bool? isFavored;
  final bool? isDeleting;

  @override
  State<UImageButton> createState() => UImageButtonState();
}

class UImageButtonState extends State<UImageButton> {
  late bool isSelected;

  @override
  void initState() {
    super.initState();
    isSelected = false;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: USizes.imageButtonHeight,
      width: USizes.imageButtonWidth,
      child: Stack(children: [
        ClipRRect(
          child: widget.uImage,
          borderRadius: BorderRadius.circular(4),
        ),
        Align(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Stack(
              children: [
                if (widget.isLinked == true)
                  const Align(
                    alignment: Alignment.topLeft,
                    child: UIcon(
                      UIcons.link,
                      color: UColors.textMed,
                    ),
                  ),
                if (widget.isFavored == true)
                  const Align(
                    alignment: Alignment.topRight,
                    child: UIcon(
                      UIcons.favorite,
                      color: UColors.textMed,
                    ),
                  ),
                if (widget.isDeleting == true)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: AnimatedCrossFade(
                      firstChild: GestureDetector(
                        child: const UIcon(
                          UIcons.select_box,
                          color: UColors.textMed,
                        ),
                        onTap: () {
                          setState(() {
                            isSelected = true;
                          });
                        },
                      ),
                      secondChild: GestureDetector(
                        child: const UIcon(
                          UIcons.checkmark_2,
                          color: UColors.termRed,
                        ),
                        onTap: () {
                          setState(() {
                            isSelected = false;
                          });
                        },
                      ),
                      crossFadeState: isSelected
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      duration: const Duration(milliseconds: 100),
                      reverseDuration: const Duration(milliseconds: 100),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
