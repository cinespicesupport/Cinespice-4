package app.cinespice.android;
import org.json.*;
import org.junit.Test;
import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;

public class NoticeHistoryTest {
    private JSONArray fixture() throws Exception {
        try (java.io.InputStream input=getClass().getResourceAsStream("/notice-history.json")) {
            assertNotNull(input); return new JSONArray(new String(input.readAllBytes(), StandardCharsets.UTF_8));
        }
    }
    @Test public void retainsTextAndMediaUntilClearWithoutResurrectingOldPages() throws Exception {
        JSONArray values=fixture(); NoticeHistory history=new NoticeHistory();
        history.ingest(values.getJSONObject(0)); history.ingest(values.getJSONObject(1)); history.ingest(values.getJSONObject(0));
        assertEquals(2,history.ordered().size()); assertEquals(20,history.ordered().get(0).getLong("id"));
        history.ingest(values.getJSONObject(3)); history.ingest(values.getJSONObject(2));
        assertEquals(1,history.ordered().size()); assertEquals(40,history.ordered().get(0).getLong("id"));
        history.ingest(values.getJSONObject(0)); history.ingest(values.getJSONObject(1)); history.ingest(values.getJSONObject(2));
        assertEquals(1,history.ordered().size()); history.remove(40); assertTrue(history.ordered().isEmpty());
    }
    @Test public void selectedDeletePreservesOtherCampaignsAndBlocksLatePages() throws Exception {
        JSONArray values=fixture(); NoticeHistory history=new NoticeHistory();
        history.ingest(values.getJSONObject(0)); history.ingest(values.getJSONObject(1)); history.ingest(values.getJSONObject(3));
        history.ingest(values.getJSONObject(4)); history.ingest(values.getJSONObject(0)); history.ingest(values.getJSONObject(1));
        assertEquals(1,history.ordered().size()); assertEquals(40,history.ordered().get(0).getLong("id"));
        NoticeHistory reloaded=new NoticeHistory();
        reloaded.ingest(values.getJSONObject(4)); reloaded.ingest(values.getJSONObject(3)); reloaded.ingest(values.getJSONObject(1)); reloaded.ingest(values.getJSONObject(0));
        assertEquals(1,reloaded.ordered().size()); assertEquals(40,reloaded.ordered().get(0).getLong("id"));
        assertEquals(0,reloaded.clearedThrough);
    }
    @Test public void permanentDeletionWinsOverInflightHistory() throws Exception {
        JSONArray values = fixture(); NoticeHistory history = new NoticeHistory();
        history.remove(values.getJSONObject(0).getLong("id"));
        history.ingest(values.getJSONObject(0)); assertTrue(history.ordered().isEmpty());
        history.ingest(values.getJSONObject(1)); assertEquals(1, history.ordered().size());
    }
    @Test public void rejectsMalformedOrUnmarkedMessages() throws Exception {
        JSONArray values=fixture(); NoticeHistory history=new NoticeHistory();
        JSONObject value=values.getJSONObject(0); value.remove("reply_markup"); history.ingest(value); assertTrue(history.ordered().isEmpty());
        value=values.getJSONObject(1); value.getJSONObject("reply_markup").getJSONArray("rows").getJSONArray(0).getJSONObject(0).getJSONObject("type").put("data","!!!!");
        history.ingest(value); assertTrue(history.ordered().isEmpty());
    }
}
