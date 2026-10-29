package app.cinespice.android;
import org.json.*;
import org.junit.Test;
import static org.junit.Assert.*;

public class AnnouncementMediaTest {
    @Test public void choosesLargestPhotoEvenWhenThumbnailIsLast() {
        JSONObject large=Json.obj("width",4000,"height",2000,"photo",Json.obj("id",1,"size",0,"expected_size",4096));
        JSONObject thumbnail=Json.obj("width",90,"height",90,"photo",Json.obj("id",2,"size",200));
        JSONObject notice=Json.obj("content",Json.obj("@type","messagePhoto","photo",Json.obj("sizes",new JSONArray().put(large).put(thumbnail))));
        assertTrue(Announcement.hasMedia(notice)); assertFalse(Announcement.animated(notice));
        assertEquals(1,Announcement.file(notice).optInt("id"));
        assertEquals(2f,Announcement.ratio(notice),.001f);
    }
    @Test public void textOnlyPostsHaveNoMediaAndMissingDimensionsAreSafe() {
        JSONObject text=Json.obj("content",Json.obj("@type","messageText"));
        assertFalse(Announcement.hasMedia(text)); assertEquals(1f,Announcement.ratio(text),.001f);
        JSONObject animation=Json.obj("content",Json.obj("@type","messageAnimation","animation",Json.obj("animation",Json.obj("id",3))));
        assertTrue(Announcement.hasMedia(animation)); assertTrue(Announcement.animated(animation));
        assertEquals(3,Announcement.file(animation).optInt("id"));
    }
}
