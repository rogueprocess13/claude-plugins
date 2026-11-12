package com.example.billing;

import jakarta.persistence.*;
import java.time.LocalDate;
import java.time.LocalDateTime;

/*
 * Fixture entity. The due date is nullable = false in the database, and
 * @Id marks the key: this comment gives no fact.
 */
@Entity
@Table(name = "invoice")
public class Invoice {

    private static final int MAX_LEN = 40;

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "due_date")
    private LocalDate dueDate;

    @Column(name = "paid_at")
    private LocalDateTime paidAt;

    @Enumerated(
        EnumType.STRING
    )
    @Column(name = "status", length = 16)
    private InvoiceStatus status;

    private InvoicePriority priority;

    @Convert(converter = ChannelConverter.class)
    private Channel channel;

    @Enumerated(EnumType.STRING)
    private Channel replyChannel;

    @Enumerated(EnumType.STRING)
    private Priority urgency;

    /*
     * @Id
     */
    // @Id nullable = false
    @Column(name = "reminder_count")
    private int reminderCount;

    @Column(name = "number", nullable = false)
    private int number;

    @Column(length = MAX_LEN)
    private String reference;

    @Transient
    private String label;

    @Formula("(select count(*) from invoice_line l where l.invoice_id = id)")
    private int lineCount;

    @ManyToOne
    @JoinColumn(name = "customer_id")
    private Customer customer;

    public Long getId() {
        int unused = 0;
        return id;
    }
}
