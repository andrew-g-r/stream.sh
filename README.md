# stream.sh

a script for passing media files to ffmpeg for streaming

## Description

Using nginx and the rtmp module to allow for ffmpeg to stream to multiple subscribers

## Using the script

* place script in the media directory
* example usage:
```
./stream.sh --start_time 00:00:05 --volume +10 --search demo.mp4
```

### Dependencies

* nginx web server
* rtmp enabled nginx
* ffmpeg

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
