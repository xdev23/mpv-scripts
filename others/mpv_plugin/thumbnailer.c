#define MPV_CPLUGIN_DYNAMIC_SYM 

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mpv/client.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>

// --- GLOBAL CACHE AND BUFFERS FOR INSTANT SCRUBBING ---
AVFormatContext *g_fmt_ctx = NULL;
AVCodecContext *g_codec_ctx = NULL;
struct SwsContext *g_sws_ctx = NULL;
int g_video_stream_idx = -1;
char g_last_video_path[2048] = {0};

// Reusable memory to avoid malloc/free overhead on every frame
AVPacket *g_pkt = NULL;
AVFrame *g_frame = NULL;
AVFrame *g_frame_bgra = NULL;
uint8_t *g_buffer = NULL;
int g_last_width = 0;
int g_last_height = 0;
int g_num_bytes = 0;

void clean_path(char *path) {
    if (path == NULL) return;
    int len = strlen(path);
    if (len >= 2 && path[0] == '"' && path[len - 1] == '"') {
        memmove(path, path + 1, len - 2);
        path[len - 2] = '\0';
    }
    int read_idx = 0;
    int write_idx = 0;
    while (path[read_idx] != '\0') {
        if (path[read_idx] == '\\' && path[read_idx + 1] == '\\') {
            path[write_idx] = '\\';
            read_idx += 2;
            write_idx += 1;
        } else {
            path[write_idx] = path[read_idx];
            read_idx += 1;
            write_idx += 1;
        }
    }
    path[write_idx] = '\0';
}

void cleanup_decoder() {
    if (g_sws_ctx) { sws_freeContext(g_sws_ctx); g_sws_ctx = NULL; }
    if (g_codec_ctx) { avcodec_free_context(&g_codec_ctx); g_codec_ctx = NULL; }
    if (g_fmt_ctx) { avformat_close_input(&g_fmt_ctx); g_fmt_ctx = NULL; }
    if (g_buffer) { av_freep(&g_buffer); }
    if (g_pkt) { av_packet_free(&g_pkt); }
    if (g_frame) { av_frame_free(&g_frame); }
    if (g_frame_bgra) { av_frame_free(&g_frame_bgra); }
    
    g_video_stream_idx = -1;
    g_last_video_path[0] = '\0';
    g_last_width = 0;
    g_last_height = 0;
}

void init_global_buffers(int width, int height) {
    if (!g_pkt) g_pkt = av_packet_alloc();
    if (!g_frame) g_frame = av_frame_alloc();
    if (!g_frame_bgra) g_frame_bgra = av_frame_alloc();

    // Only re-allocate image buffers if the resolution changed
    if (g_last_width != width || g_last_height != height || !g_buffer) {
        if (g_buffer) av_freep(&g_buffer);
        g_num_bytes = av_image_get_buffer_size(AV_PIX_FMT_BGRA, width, height, 1);
        g_buffer = (uint8_t *)av_malloc(g_num_bytes * sizeof(uint8_t));
        av_image_fill_arrays(g_frame_bgra->data, g_frame_bgra->linesize, g_buffer, AV_PIX_FMT_BGRA, width, height, 1);
        g_last_width = width;
        g_last_height = height;
    }
}

int extract_frame(const char* video_path, const char* out_path, double time_sec, int width, int height) {
    int needs_sws_update = 0;

    // 1. OPEN VIDEO ONCE
    if (strcmp(g_last_video_path, video_path) != 0) {
        cleanup_decoder(); 
        if (avformat_open_input(&g_fmt_ctx, video_path, NULL, NULL) < 0) return 0;
        if (avformat_find_stream_info(g_fmt_ctx, NULL) < 0) { cleanup_decoder(); return 0; }

        for (int i = 0; i < g_fmt_ctx->nb_streams; i++) {
            if (g_fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                g_video_stream_idx = i;
                break;
            }
        }
        if (g_video_stream_idx == -1) { cleanup_decoder(); return 0; }

        const AVCodec *codec = avcodec_find_decoder(g_fmt_ctx->streams[g_video_stream_idx]->codecpar->codec_id);
        g_codec_ctx = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(g_codec_ctx, g_fmt_ctx->streams[g_video_stream_idx]->codecpar);
        
        // Fast decoding flags
        g_codec_ctx->thread_count = 1; 
        g_codec_ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        g_codec_ctx->flags2 |= AV_CODEC_FLAG2_FAST;
        
        if (avcodec_open2(g_codec_ctx, codec, NULL) < 0) { cleanup_decoder(); return 0; }
        strncpy(g_last_video_path, video_path, sizeof(g_last_video_path) - 1);
        needs_sws_update = 1;
    } 
    else if (g_last_width != width || g_last_height != height) {
        needs_sws_update = 1;
    }

    if (!g_fmt_ctx || !g_codec_ctx) return 0;

    init_global_buffers(width, height);

    if (needs_sws_update) {
        if (g_sws_ctx) sws_freeContext(g_sws_ctx);
        g_sws_ctx = sws_getContext(g_codec_ctx->width, g_codec_ctx->height, g_codec_ctx->pix_fmt,
                                   width, height, AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL);
    }

    // 2. SEEK TO KEYFRAME
    int64_t seek_target = time_sec * AV_TIME_BASE;
    avformat_seek_file(g_fmt_ctx, -1, INT64_MIN, seek_target, seek_target, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(g_codec_ctx);

    int frame_decoded = 0;

    // 3. ONLY DECODE THE FIRST FRAME WE SEE (INSTANT!)
    // Instead of wasting time looping to the exact millisecond, grab the nearest keyframe.
    while (av_read_frame(g_fmt_ctx, g_pkt) >= 0) {
        if (g_pkt->stream_index == g_video_stream_idx) {
            if (avcodec_send_packet(g_codec_ctx, g_pkt) == 0) {
                if (avcodec_receive_frame(g_codec_ctx, g_frame) == 0) {
                    frame_decoded = 1;
                    av_packet_unref(g_pkt); // Free packet memory immediately
                    break; // STOP DECODING IMMEDIATELY. WE GOT A FRAME.
                }
            }
        }
        av_packet_unref(g_pkt);
    }

    // 4. SCALE AND SAVE DIRECTLY TO DISK
    if (frame_decoded && g_sws_ctx) {
        sws_scale(g_sws_ctx, (uint8_t const * const *)g_frame->data, g_frame->linesize, 0, g_codec_ctx->height,
                  g_frame_bgra->data, g_frame_bgra->linesize);
                  
        FILE *f = fopen(out_path, "wb");
        if (f) {
            fwrite(g_frame_bgra->data[0], 1, g_num_bytes, f);
            fclose(f);
        } else {
            frame_decoded = 0;
        }
    }

    return frame_decoded;
}

__declspec(dllexport) int mpv_open_cplugin(mpv_handle *ctx) {
    mpv_observe_property(ctx, 1, "user-data/c_plugin/request_time", MPV_FORMAT_DOUBLE);

    // We process every single event instantly, dropping nothing.
    while (1) {
        mpv_event *event = mpv_wait_event(ctx, -1);
        
        if (event->event_id == MPV_EVENT_SHUTDOWN) {
            cleanup_decoder();
            break;
        }
        
        if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *prop = event->data;
            if (strcmp(prop->name, "user-data/c_plugin/request_time") == 0) {
                if (prop->format != MPV_FORMAT_DOUBLE || prop->data == NULL) continue; 
                
                double req_time = *(double *)prop->data;
                if (req_time >= 0) {
                    char *out_path = mpv_get_property_string(ctx, "user-data/c_plugin/out_path");
                    char *video_path = mpv_get_property_string(ctx, "path");
                    
                    if (!out_path || !video_path || strlen(video_path) == 0) {
                        if (out_path) mpv_free(out_path);
                        if (video_path) mpv_free(video_path);
                        continue;
                    }

                    clean_path(out_path);
                    clean_path(video_path);

                    double w = 350.0, h = 350.0;
                    mpv_get_property(ctx, "user-data/c_plugin/width", MPV_FORMAT_DOUBLE, &w);
                    mpv_get_property(ctx, "user-data/c_plugin/height", MPV_FORMAT_DOUBLE, &h);

                    // Extract and save instantly
                    if (extract_frame(video_path, out_path, req_time, (int)w, (int)h) == 1) {
                        mpv_set_property_async(ctx, 0, "user-data/c_plugin/ready_time", MPV_FORMAT_DOUBLE, &req_time);
                    }
                    
                    mpv_free(out_path);
                    mpv_free(video_path);
                }
            }
        }
    }
    return 0;
}