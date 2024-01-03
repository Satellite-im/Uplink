
# iso/iec 14996-12
- hopefully can use this spec to use this crate: https://docs.rs/mp4/0.13.0/

# Chapter 4: Object-structured file organization
- files are formed as a series of objects, called boxes. All data is contained within boxes. All object-structured files shall contain a `FileTypeBox`. 
- the definitions of objects are given in the syntax description language (SDL) defined in 14496-1. 
- the fields in the objects are stored in big endian format (MSB first). 
- boxes start with a header which gives both size and type. The header permits compact (32 bits) or extended (64 bits) size and compact or extended types (32 bit or full UUID). Typically, only the `MediaDataBox` needs the 64-bit size. 
- the 32-bit compact type can be expressed as 4 characters from the range 0020 to 007E. Each character is expressible by a single byte. A 'four character code' (4CC) may also be used. their format is defined in Annex D. 
- the size field of the box header is for both the header and data. 

given some pseudocode. see page 8
```
aligned(8) class BoxHeader (
    unsigned int(32) boxtype,
    optional unsigned int(8)[16] extended_type) 
{
    unsigned int(32) size; // specifies the number of bytes in the box, including all its fields and contained boxes. 
    unsigned int(32) type = boxtype;
    if (size==1) {
        unsigned int(64) largesize;
    } else if (size==0) {
        // box extends to end of file
    }
    if (boxtype=='uuid') {
        unsigned int(8)[16] usertype = extended_type;
    }
}
aligned(8) class Box (
    unsigned int(32) boxtype,
    optional unsigned int(8)[16] extended_type) 
{
    BoxHeader(boxtype, extended_type);
    // the remaining bytes are the BoxPayload
}
```

the code continues on page 9
```
aligned(8) class FullBoxHeader(unsigned int(8) v, bit(24) f)
{
    unsigned int(8) version = v;
    bit(24) flags = f;
}
aligned(8) class FullBox(unsigned int(32) boxtype,
    unsigned int(8) v, bit(24) f,
    optional unsigned int(8)[16] extended_type)
    extends Box(boxtype, extended_type)
{
    FullBoxHeader(v, f);
    // the remaining bytes are the FullBoxPayload
}
```

## 4.3: File-type box
- Box type 'ftyp'
- manditory - must be exactly one. 
- should be placed before any `MovieBox`, `MediaDataBox`, or `FreeSpaceBox`. 
```
aligned(8) class GeneralTypeBox(code) extends Box(code) {
    unsigned int(32) major_brand;
    unsigned int(32) minor_version;
    unsigned int(32) compatible_brands[]; // to end of the box
}

aligned(8) class FileTypeBox extends GeneralTypeBox ('ftyp')
{}
```

## 4.4: extended type box
- box type 'etyp'
    - not mandatory
- box type 'tyco'
    - mandatory - one or more
- the `ExtendedTypeBox` may be placed after the `FileTypeBox`, any `SegmentTypeBox`, or any `TrackTypeBox`, or used as an item property to specify the processing requirements for the file. 

# Chapter 6: ISO base media file organization

## 6.1
- 3 ways to structure an mp4 file
    - single file
    - series of segments, preceded by an initialization segment
    - transformed by supporting structures, called hint tracks, into a streaming protocol such as RTP or an MPEG-2 transport stream
- a file that supports streaming includes information about the data units to stream. this information is included in additional tracks to the file called "hint tracks". Hint tracks may also be used to record a stream. 

## 6.2 Presentation structure
- the presentation file is an object-structured file as defined in section 4. Presentation files contain data that structures, orders, times, and describes the media data that is passed to decoders. This non-media data is called structure data. 
- the sequence of objects in a presentation shall contain exactly one `MovieBox`. The other objects found at this level include a `FileTypeBox`, `FreeSpaceBox`, `MovieFragmentBox`, `MetaBox`. 

## 6.3: structure-data
- a table of box types is on page 15
- mandatory boxes are marked with an asterisk
- box order shown in section 6.3.4
    - the `FileTypeBox` shall occur before any variable-length box
    - recommended that all header boxes be placed first in their container
    - movie fragment boxes should be in sequence order
    - recommended order of boxes within the `SampleTableBox`: `SampleDescriptionBox`, `TimeToSampleBox`, `SampleToChunkBox`, `SampleSizeBox`, `ChunkOffsetBox`
    - recommended that `TrackReferenceBox` and `EditBox` precede the `MediaBox`, and `HandlerBox` should precede the `MediaInformationBox`
    - see document for more recommendations. 

# Chapter 8: Box structures


# Annex A: background and tutorial
- in the file format, the overall presentation is called a movie.
- Hint tracks contain instructions for a streaming server in how to form packets for a streaming protocol. 
- edit list: allows the movement of portions of the timeline of a track, and also the insertion of blank time (empty edits). if a track does not start at the beginning of a presentation, an initial empty edit is needed. 
- video tracks can be composed - layered on to each other. 

## A.10 fragmented movie files
- benefits (mainly for recording)
    - prevents data loss in event of a crash. good for recording. 
    - uses less RAM
    - allows for HTTP fast-start
    - allows for segment based streaming
- the movie box (moov) may have few or no samples in its tracks
- to this minimal or empty movie, extra samples are added, in structures called movie fragments. 
- defaults are set for each sample, both globally (once per track) and within each fragment (if the default value needs to change). 
- the movie box still needs
    - to represent a valid movie, even if the tracks have no samples
    - contain a box to indicate that fragments should be found and used (MovieExtendsBox)
    - contains the complete edit list (if any). 

## A.11 Construction of fragmented movies
- recommended order of boxes
    - FileTypeBox
    - MovieBox
    - pair of MovieFragmentBox and MediaDataBox
    - MovieFragmentRandomAccessBox
- a MovieFragmentBox consists of at most one TrackFragmentBox for each track.
- the first samples for each track are stored in the MovieFragmentRandomAccessBox (Optional) 

# Annex E: file format brands
- if you say the file is 'isom', then specific boxes are required. same for 'avc1', 'isom2', etc. see this annex for the list. 

# Annex H: processing of RTP streams and reception hint tracks
- need to use RTCP sender reports to align the RTP timestamps of different streams onto the same wallclock timeline

# annex K - rfc 6381
- specifies parameters that are used with various MIME types to allow for unambiguous specification of the codecs employed by the media formats. 