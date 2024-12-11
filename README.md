# stream.sh

a script for passing media files to ffmpeg for streaming

## Description

Using nginx and the rtmp module to allow for ffmpeg to stream to multiple subscribers

## Getting Started

### Dependencies

* nginx web server
* rtmp enabled nginx

### configuring nginx

* nginx.conf
```
 rtmp {
   server {
     listen 1935;
     chunk_size 4000;

     application live_stream {
       allow play all;
       live on;
     }
   }
 }
```

### reload nginx

* reload changes to nginx.conf
```
nginx -t && nginx -s reload
```

## Authors

Andrew Russell

## Version History

* 0.1
    * Initial Release
