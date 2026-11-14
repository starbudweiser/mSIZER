// mSIZER — accès simples aux champs de LibRaw (évite les tuples Swift des tableaux C).
#ifndef RAWSHIM_H
#define RAWSHIM_H
#include <libraw/libraw.h>
#include <string.h>

static inline int rs_raw_w(libraw_data_t *d)   { return d->sizes.raw_width; }
static inline int rs_raw_h(libraw_data_t *d)   { return d->sizes.raw_height; }
static inline int rs_raw_pitch(libraw_data_t *d) { return (int)d->sizes.raw_pitch; }
static inline int rs_w(libraw_data_t *d)       { return d->sizes.width; }
static inline int rs_h(libraw_data_t *d)       { return d->sizes.height; }
static inline int rs_top(libraw_data_t *d)     { return d->sizes.top_margin; }
static inline int rs_left(libraw_data_t *d)    { return d->sizes.left_margin; }
static inline int rs_flip(libraw_data_t *d)    { return d->sizes.flip; }
static inline const unsigned short *rs_raw(libraw_data_t *d) { return d->rawdata.raw_image; }
static inline int rs_has_raw4(libraw_data_t *d) { return d->rawdata.color4_image != 0 || d->rawdata.color3_image != 0; }

static inline unsigned rs_filters(libraw_data_t *d) { return d->idata.filters; }
static inline int rs_colors(libraw_data_t *d)  { return d->idata.colors; }
static inline int rs_is_foveon(libraw_data_t *d) { return (int)d->idata.is_foveon; }
static inline unsigned rs_dng_version(libraw_data_t *d) { return d->idata.dng_version; }
static inline int rs_xtrans(libraw_data_t *d, int r, int c) { return d->idata.xtrans[r][c]; }
static inline const char *rs_make(libraw_data_t *d)  { return d->idata.make; }
static inline const char *rs_model(libraw_data_t *d) { return d->idata.model; }
static inline const char *rs_nmake(libraw_data_t *d)  { return d->idata.normalized_make; }
static inline const char *rs_nmodel(libraw_data_t *d) { return d->idata.normalized_model; }
static inline const char *rs_lens(libraw_data_t *d) { return d->lens.Lens; }
static inline const char *rs_artist(libraw_data_t *d) { return d->other.artist; }

static inline unsigned rs_black(libraw_data_t *d)   { return d->color.black; }
static inline unsigned rs_cblack(libraw_data_t *d, int i) { return d->color.cblack[i]; }
static inline unsigned rs_maximum(libraw_data_t *d) { return d->color.maximum; }
static inline unsigned rs_data_maximum(libraw_data_t *d) { return d->color.data_maximum; }
static inline float rs_cam_mul(libraw_data_t *d, int i) { return d->color.cam_mul[i]; }
static inline float rs_cam_xyz(libraw_data_t *d, int r, int c) { return d->color.cam_xyz[r][c]; }
static inline float rs_dng_cm(libraw_data_t *d, int r, int c) { return d->color.dng_color[0].colormatrix[r][c]; }
static inline float rs_rgb_cam(libraw_data_t *d, int r, int c) { return d->color.rgb_cam[r][c]; }

static inline float rs_iso(libraw_data_t *d)      { return d->other.iso_speed; }
static inline float rs_shutter(libraw_data_t *d)  { return d->other.shutter; }
static inline float rs_aperture(libraw_data_t *d) { return d->other.aperture; }
static inline float rs_focal(libraw_data_t *d)    { return d->other.focal_len; }
static inline long  rs_timestamp(libraw_data_t *d) { return (long)d->other.timestamp; }

static inline int rs_thumb_format(libraw_data_t *d) { return (int)d->thumbnail.tformat; }
static inline const char *rs_thumb_data(libraw_data_t *d) { return d->thumbnail.thumb; }
static inline unsigned rs_thumb_len(libraw_data_t *d) { return d->thumbnail.tlength; }
static inline int rs_thumb_w(libraw_data_t *d) { return d->thumbnail.twidth; }
static inline int rs_thumb_h(libraw_data_t *d) { return d->thumbnail.theight; }

#endif
