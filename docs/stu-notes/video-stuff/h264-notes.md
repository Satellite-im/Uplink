
using the openh264 crate, have to implement a YUV source https://docs.rs/openh264/0.4.1/openh264/formats/trait.YUVSource.html which provides 3 arrays. not sure how to go from RGB (width/height triples) to this

answer:
https://docs.kernel.org/userspace-api/media/v4l/pixfmt-yuv-planar.html

it's a fully planar format, using a plane to store Y, Cb, and Cr components separately. 


# Y'UV
- https://en.wikipedia.org/wiki/YUV
- Y' is the luma: brightness in an image - the antichromatic portion of the image
    - the weighted sum of gamma compressed R'G'B' components of a color video. 
- U is blue - luma
- V is red - luma
- this format separates color from a signal, so black and white TVs could ignore the color part of the signal. 
- picture of the UV plane (called CbCr here): https://en.wikipedia.org/wiki/YCbCr

- more conversions https://web.archive.org/web/20180423091842/http://www.equasys.de/colorconversion.html

# misc
the h264 spec is now free https://www.itu.int/rec/T-REC-H.264-202108-I/en. previously had to pay for part 10 of the mpeg-4 spec

according to wikipedia's page on YCbCr under RGB conversion, there are many types of YUV formats. OpenH264 uses YUV420
- https://saturncloud.io/blog/rgb-to-yuv420-algorithm-efficiency-a-deep-dive/