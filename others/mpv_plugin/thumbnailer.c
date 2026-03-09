#define MPV_CPLUGIN_DYNAMIC_SYM 

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mpv/client.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>

// --- GLOBAL CACHE FOR BLAZING FAST SPEEDS ---
AVFormatContext *g_fmt_ctx = NULL;
AVCodecContext *g_codec_ctx = NULL;
struct SwsContext *g_sws_ctx = NULL;
int g_video_stream_idx = -1;
char g_last_video_path[2048] = {0};
AVRational g_time_base;

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

// Clears the cache when mpv closes or the video changes
void cleanup_decoder() {
    if (g_sws_ctx) { sws_freeContext(g_sws_ctx); g_sws_ctx = NULL; }
    if (g_codec_ctx) { avcodec_free_context(&g_codec_ctx); g_codec_ctx = NULL; }
    if (g_fmt_ctx) { avformat_close_input(&g_fmt_ctx); g_fmt_ctx = NULL; }
    g_video_stream_idx = -1;
    g_last_video_path[0] = '\0';
}

int extract_frame(const char* video_path, const char* out_path, double time_sec, int width, int height) {
    // 1. ONLY OPEN THE FILE IF IT'S A NEW VIDEO (This fixes the slow speed!)
    if (strcmp(g_last_video_path, video_path) != 0) {
        cleanup_decoder(); // Close old video if we switched files
        
        if (avformat_open_input(&g_fmt_ctx, video_path, NULL, NULL) < 0) return 0;
        if (avformat_find_stream_info(g_fmt_ctx, NULL) < 0) { cleanup_decoder(); return 0; }

        for (int i = 0; i < g_fmt_ctx->nb_streams; i++) {
            if (g_fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                g_video_stream_idx = i;
                g_time_base = g_fmt_ctx->streams[i]->time_base;
                break;
            }
        }
        if (g_video_stream_idx == -1) { cleanup_decoder(); return 0; }

        const AVCodec *codec = avcodec_find_decoder(g_fmt_ctx->streams[g_video_stream_idx]->codecpar->codec_id);
        g_codec_ctx = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(g_codec_ctx, g_fmt_ctx->streams[g_video_stream_idx]->codecpar);
        g_codec_ctx->thread_count = 1; 
        
        if (avcodec_open2(g_codec_ctx, codec, NULL) < 0) { cleanup_decoder(); return 0; }
        
        strncpy(g_last_video_path, video_path, sizeof(g_last_video_path) - 1);
        
        g_sws_ctx = sws_getContext(g_codec_ctx->width, g_codec_ctx->height, g_codec_ctx->pix_fmt,
                                   width, height, AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL);
    }

    if (!g_fmt_ctx || !g_codec_ctx) return 0;

    // 2. SEEK TO THE NEAREST KEYFRAME
    int64_t seek_target = time_sec * AV_TIME_BASE;
    avformat_seek_file(g_fmt_ctx, -1, INT64_MIN, seek_target, seek_target, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(g_codec_ctx); // VERY IMPORTANT AFTER SEEKING

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    AVFrame *frame_bgra = av_frame_alloc();
    int frame_decoded = 0;

    int num_bytes = av_image_get_buffer_size(AV_PIX_FMT_BGRA, width, height, 1);
    uint8_t *buffer = (uint8_t *)av_malloc(num_bytes * sizeof(uint8_t));
    av_image_fill_arrays(frame_bgra->data, frame_bgra->linesize, buffer, AV_PIX_FMT_BGRA, width, height, 1);

    // 3. READ FORWARD UNTIL WE HIT THE EXACT TIMESTAMP (This fixes the accuracy!)
    while (av_read_frame(g_fmt_ctx, pkt) >= 0) {
        if (pkt->stream_index == g_video_stream_idx) {
            if (avcodec_send_packet(g_codec_ctx, pkt) == 0) {
                while (avcodec_receive_frame(g_codec_ctx, frame) == 0) {
                    
                    // Convert the internal frame timestamp into actual seconds
                    double current_sec = frame->best_effort_timestamp * av_q2d(g_time_base);
                    
                    // Keep decoding and tossing frames until we reach the hover time
                    if (current_sec >= time_sec || current_sec < 0) {
                        frame_decoded = 1;
                        break;
                    }
                }
            }
        }
        av_packet_unref(pkt);
        if (frame_decoded) break;
    }

    // 4. SAVE THE EXACT FRAME
    if (frame_decoded && g_sws_ctx) {
        sws_scale(g_sws_ctx, (uint8_t const * const *)frame->data, frame->linesize, 0, g_codec_ctx->height,
                  frame_bgra->data, frame_bgra->linesize);
                  
        FILE *f = fopen(out_path, "wb");
        if (f) {
            fwrite(frame_bgra->data[0], 1, num_bytes, f);
            fclose(f);
        } else {
            frame_decoded = 0;
        }
    }

    // 5. CLEANUP ONLY TEMPORARY BUFFERS (Leave the video file open for the next hover!)
    av_free(buffer);
    av_frame_free(&frame_bgra);
    av_frame_free(&frame);
    av_packet_free(&pkt);

    return frame_decoded;
}

__declspec(dllexport) int mpv_open_cplugin(mpv_handle *ctx) {
    mpv_observe_property(ctx, 1, "user-data/c_plugin/request_time", MPV_FORMAT_DOUBLE);
    while (1) {
        mpv_event *event = mpv_wait_event(ctx, -1);
        
        // Clean up global memory if the user closes mpv
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